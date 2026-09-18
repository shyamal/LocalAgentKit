// Validates the eval suites in EvalSuites/ against their tool catalog.
// Run: swift Scripts/validate-eval-suites.swift [EvalSuites/phase0]
// Exits non-zero on any inconsistency. Checks structure only — it does not run a model.
import Foundation

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "EvalSuites/phase0"
var errors: [String] = []

func load(_ path: String) -> [String: Any]? {
  guard let data = FileManager.default.contents(atPath: path) else {
    errors.append("\(path): cannot read")
    return nil
  }
  do {
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      errors.append("\(path): top level is not an object")
      return nil
    }
    return obj
  } catch {
    errors.append("\(path): invalid JSON — \(error.localizedDescription)")
    return nil
  }
}

let confirmationTiers: Set<String> = ["userConfirmation", "sensitive", "destructive"]
let knownTiers = confirmationTiers.union(["none", "readOnly"])
let requiredFields: [String: [String]] = [
  "exact": ["value"], "caseInsensitive": ["value"], "containsAll": ["terms"],
  "containsAny": ["terms"], "evaluatesTo": ["tolerance"],
  "datetime": ["value", "toleranceMinutes"], "date": ["value", "toleranceDays"], "absent": [],
]
let dateTimePattern = #/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/#
let datePattern = #/^\d{4}-\d{2}-\d{2}$/#

guard let catalog = load("\(dir)/tools.json"), let toolList = catalog["tools"] as? [[String: Any]]
else {
  errors.append("\(dir)/tools.json: missing or has no tools array")
  for error in errors { print("error: \(error)") }
  exit(1)
}

var tools: [String: [String: Any]] = [:]
for tool in toolList {
  guard let name = tool["name"] as? String else {
    errors.append("tools.json: tool without a name")
    continue
  }
  if tools[name] != nil { errors.append("tools.json: duplicate tool \(name)") }
  if name.wholeMatch(of: #/[a-z]+(_[a-z]+)*/#) == nil {
    errors.append("tools.json: \(name) is not snake_case")
  }
  if !knownTiers.contains(tool["permission"] as? String ?? "") {
    errors.append("tools.json: \(name) has unknown permission tier")
  }
  tools[name] = tool
}

func requiresConfirmation(_ toolName: String) -> Bool {
  confirmationTiers.contains(tools[toolName]?["permission"] as? String ?? "")
}

/// Checks a set of argument matchers against a tool's schema. Returns the `groundedIn`
/// references found, so step-level checks can verify them.
@discardableResult
func checkArguments(_ at: String, tool toolName: String, _ args: [String: [String: Any]])
  -> [(argument: String, step: String)]
{
  guard let tool = tools[toolName] else {
    errors.append("\(at): tool \(toolName) not in catalog")
    return []
  }
  let schema = tool["arguments"] as? [String: [String: Any]] ?? [:]
  var grounded: [(argument: String, step: String)] = []
  for (argName, matcher) in args {
    guard let argSchema = schema[argName] else {
      errors.append("\(at): argument \(argName) not in \(toolName)'s schema")
      continue
    }
    let kind = matcher["match"] as? String ?? ""
    guard let fields = requiredFields[kind] else {
      errors.append("\(at): \(argName) has unknown matcher '\(kind)'")
      continue
    }
    for field in fields where matcher[field] == nil {
      errors.append("\(at): \(argName) matcher '\(kind)' needs '\(field)'")
    }
    if kind == "evaluatesTo", (matcher["value"] == nil) == (matcher["values"] == nil) {
      errors.append("\(at): \(argName) evaluatesTo needs exactly one of 'value' or 'values'")
    }
    if kind == "absent", argSchema["required"] as? Bool == true {
      errors.append("\(at): \(argName) is required, so 'absent' can never pass")
    }
    if kind == "datetime", let value = matcher["value"] as? String,
      value.wholeMatch(of: dateTimePattern) == nil
    {
      errors.append("\(at): \(argName) datetime '\(value)' is not YYYY-MM-DDTHH:MM")
    }
    if kind == "date", let value = matcher["value"] as? String,
      value.wholeMatch(of: datePattern) == nil
    {
      errors.append("\(at): \(argName) date '\(value)' is not YYYY-MM-DD")
    }
    if kind == "exact", let allowed = argSchema["enum"] as? [String],
      let value = matcher["value"] as? String, !allowed.contains(value)
    {
      errors.append("\(at): \(argName) '\(value)' is outside the schema enum")
    }
    if let step = matcher["groundedIn"] as? String { grounded.append((argName, step)) }
  }
  return grounded
}

func checkSingleTool(_ at: String, _ goal: [String: Any]) {
  guard let expected = goal["expected"] as? [String: Any],
    let toolName = expected["tool"] as? String, tools[toolName] != nil
  else {
    errors.append("\(at): expected.tool missing or not in catalog")
    return
  }
  if let confirm = goal["expectsConfirmation"] as? Bool, confirm != requiresConfirmation(toolName) {
    errors.append("\(at): expectsConfirmation=\(confirm) contradicts \(toolName)'s permission tier")
  }
  checkArguments(at, tool: toolName, expected["arguments"] as? [String: [String: Any]] ?? [:])
}

func checkMultiStep(_ at: String, _ goal: [String: Any]) {
  let steps = goal["steps"] as? [[String: Any]] ?? []
  if !(3...5).contains(steps.count) {
    errors.append("\(at): has \(steps.count) steps; multi-step goals need 3–5")
  }
  // dependsOn may only name earlier steps, which keeps the graph acyclic by construction.
  var ancestors: [String: Set<String>] = [:]
  var requiredTools = Set<String>()
  for step in steps {
    let id = step["id"] as? String ?? "<missing id>"
    let stepAt = "\(at) step \(id)"
    if ancestors[id] != nil { errors.append("\(stepAt): duplicate step id") }
    let toolName = step["tool"] as? String ?? ""
    if step["optional"] as? Bool != true { requiredTools.insert(toolName) }
    var chain = Set<String>()
    for dependency in step["dependsOn"] as? [String] ?? [] {
      guard let upstream = ancestors[dependency] else {
        errors.append("\(stepAt): dependsOn '\(dependency)' is not an earlier step")
        continue
      }
      chain.insert(dependency)
      chain.formUnion(upstream)
    }
    let args = step["arguments"] as? [String: [String: Any]] ?? [:]
    for (argument, source) in checkArguments(stepAt, tool: toolName, args)
    where !chain.contains(source) {
      errors.append(
        "\(stepAt): \(argument) groundedIn '\(source)', which is not in its dependsOn chain")
    }
    ancestors[id] = chain
  }
  let maxIterations = goal["maxIterations"] as? Int ?? 0
  if maxIterations < steps.count {
    errors.append("\(at): maxIterations \(maxIterations) is below its \(steps.count) steps")
  }
  for tool in goal["forbidden"] as? [String] ?? [] {
    if tools[tool] == nil { errors.append("\(at): forbidden tool \(tool) not in catalog") }
    if requiredTools.contains(tool) {
      errors.append("\(at): \(tool) is both forbidden and a required step")
    }
  }
  for (index, fixture) in (goal["fixtures"] as? [[String: Any]] ?? []).enumerated() {
    let fixtureAt = "\(at) fixture \(index)"
    let toolName = fixture["tool"] as? String ?? ""
    if toolName == "calculate" {
      errors.append("\(fixtureAt): calculate is evaluated by the runner, never fixtured")
    }
    if (fixture["returns"] as? String ?? "").isEmpty {
      errors.append("\(fixtureAt): empty 'returns'")
    }
    checkArguments(fixtureAt, tool: toolName, fixture["when"] as? [String: [String: Any]] ?? [:])
  }
}

var goalCount = 0
let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.sorted() ?? []
for file in files where file.hasSuffix(".json") && file != "tools.json" {
  guard let suite = load("\(dir)/\(file)"), let goals = suite["goals"] as? [[String: Any]] else {
    errors.append("\(file): no goals array")
    continue
  }
  var ids = Set<String>()
  for goal in goals {
    goalCount += 1
    let id = goal["id"] as? String ?? "<missing id>"
    let at = "\(file) \(id)"
    if !ids.insert(id).inserted { errors.append("\(at): duplicate id") }
    if (goal["goal"] as? String ?? "").isEmpty { errors.append("\(at): empty goal text") }
    switch (goal["expected"] != nil, goal["steps"] != nil) {
    case (true, false): checkSingleTool(at, goal)
    case (false, true): checkMultiStep(at, goal)
    default: errors.append("\(at): needs exactly one of 'expected' or 'steps'")
    }
  }
}

if errors.isEmpty {
  print("Eval suites valid: \(goalCount) goals against \(tools.count) tools in \(dir).")
} else {
  for error in errors { print("error: \(error)") }
  exit(1)
}
