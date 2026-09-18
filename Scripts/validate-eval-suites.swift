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
  "containsAny": ["terms"], "evaluatesTo": ["value", "tolerance"],
  "datetime": ["value", "toleranceMinutes"], "absent": [],
]
let dateTimePattern = #/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/#

let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.sorted() ?? []
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

var goalCount = 0
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
    guard let expected = goal["expected"] as? [String: Any],
      let toolName = expected["tool"] as? String, let tool = tools[toolName]
    else {
      errors.append("\(at): expected.tool missing or not in catalog")
      continue
    }
    let tier = tool["permission"] as? String ?? ""
    if let confirm = goal["expectsConfirmation"] as? Bool,
      confirm != confirmationTiers.contains(tier)
    {
      errors.append("\(at): expectsConfirmation=\(confirm) contradicts \(toolName)'s \(tier) tier")
    }
    let schema = tool["arguments"] as? [String: [String: Any]] ?? [:]
    let args = expected["arguments"] as? [String: [String: Any]] ?? [:]
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
      if kind == "absent", argSchema["required"] as? Bool == true {
        errors.append("\(at): \(argName) is required, so 'absent' can never pass")
      }
      if kind == "datetime", let value = matcher["value"] as? String,
        value.wholeMatch(of: dateTimePattern) == nil
      {
        errors.append("\(at): \(argName) datetime '\(value)' is not YYYY-MM-DDTHH:MM")
      }
      if kind == "exact", let allowed = argSchema["enum"] as? [String],
        let value = matcher["value"] as? String, !allowed.contains(value)
      {
        errors.append("\(at): \(argName) '\(value)' is outside the schema enum")
      }
    }
  }
}

if errors.isEmpty {
  print("Eval suites valid: \(goalCount) goals against \(tools.count) tools in \(dir).")
} else {
  for error in errors { print("error: \(error)") }
  exit(1)
}
