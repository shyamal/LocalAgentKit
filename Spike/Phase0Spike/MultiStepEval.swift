import Foundation
import FoundationModels

// P0-10: runs Sources/LocalAgentKitEval/Suites/phase0/multi-step.json. Tools answer from each goal's fixtures;
// calculate is evaluated for real. Scoring follows the suite's `scoring` section.

struct RecordedCall: Sendable {
  let tool: String
  let json: String
}

enum MultiStepStop: Error {
  case maxIterationsReached(Int)
}

/// Serves fixture results and records every call in order. An actor because tools must be
/// Sendable and run off the main actor, while the record is shared mutable state.
actor FixtureRouter {
  private let fixtures: [[String: Any]]
  private let defaultResult: String
  private let maxCalls: Int
  private(set) var calls: [RecordedCall] = []

  /// Fixtures arrive as encoded JSON: `Data` is Sendable, `[[String: Any]]` is not.
  init(fixturesJSON: Data, defaultResult: String, maxCalls: Int) {
    fixtures = (try? JSONSerialization.jsonObject(with: fixturesJSON) as? [[String: Any]]) ?? []
    self.defaultResult = defaultResult
    self.maxCalls = maxCalls
  }

  func handle(tool: String, json: String) throws -> String {
    calls.append(RecordedCall(tool: tool, json: json))
    // Enforce maxIterations from inside the loop: the framework runs the whole tool loop
    // within one respond(), so throwing here is the only way to stop it.
    if calls.count > maxCalls { throw MultiStepStop.maxIterationsReached(maxCalls) }
    let arguments = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    if tool == "calculate" {
      let expression = arguments["expression"] as? String ?? ""
      return Arithmetic.evaluate(expression).map { String($0) }
        ?? "Error: could not evaluate '\(expression)'."
    }
    for fixture in fixtures where fixture["tool"] as? String == tool {
      let when = fixture["when"] as? [String: [String: Any]] ?? [:]
      if when.allSatisfy({ matcherFailure($0.value, value: arguments[$0.key]) == nil }) {
        return fixture["returns"] as? String ?? defaultResult
      }
    }
    return defaultResult
  }
}

/// A catalog tool whose results come from the goal's fixtures.
struct FixtureTool: Tool {
  let name: String
  let description: String
  let parameters: GenerationSchema
  let router: FixtureRouter

  init(_ spec: Catalog.ToolSpec, router: FixtureRouter) throws {
    let catalogTool = try CatalogTool(spec)
    name = catalogTool.name
    description = catalogTool.description
    parameters = catalogTool.parameters
    self.router = router
  }

  func call(arguments: GeneratedContent) async throws -> String {
    try await router.handle(tool: name, json: arguments.jsonString)
  }
}

struct MultiStepOutcome {
  let completed: Bool
  let matched: Int
  let required: Int
  let firstUnmatched: String?
  let forbiddenCalled: [String]
  let overConfirmed: [String]
}

/// Matches expected steps to recorded calls in dependency order, per the suite's `stepMatching`.
func scoreMultiStep(
  goal: [String: Any], calls: [RecordedCall], confirmationTools: Set<String>, hitLimit: Bool
) -> MultiStepOutcome {
  let steps = goal["steps"] as? [[String: Any]] ?? []
  let parsed = calls.map {
    (tool: $0.tool, args: (try? JSONSerialization.jsonObject(with: Data($0.json.utf8)) as? [String: Any]) ?? [:])
  }
  var matchedIndex: [String: Int] = [:]
  var used = Set<Int>()
  var firstUnmatched: String?
  var required = 0
  var matchedRequired = 0
  for step in steps {
    let id = step["id"] as? String ?? ""
    let optional = step["optional"] as? Bool ?? false
    if !optional { required += 1 }
    // A dependency on an optional step that never happened doesn't block its dependents.
    let after = (step["dependsOn"] as? [String] ?? []).compactMap { matchedIndex[$0] }.max() ?? -1
    let matchers = step["arguments"] as? [String: [String: Any]] ?? [:]
    let hit = parsed.indices.first { index in
      index > after && !used.contains(index) && parsed[index].tool == step["tool"] as? String
        && matchers.allSatisfy { matcherFailure($0.value, value: parsed[index].args[$0.key]) == nil }
    }
    if let hit {
      matchedIndex[id] = hit
      used.insert(hit)
      if !optional { matchedRequired += 1 }
    } else if !optional, firstUnmatched == nil {
      firstUnmatched = id
    }
  }
  let forbidden = Set(goal["forbidden"] as? [String] ?? [])
  let forbiddenCalled = parsed.map(\.tool).filter { forbidden.contains($0) }
  var expectedCount: [String: Int] = [:]
  for step in steps { expectedCount[step["tool"] as? String ?? "", default: 0] += 1 }
  var actualCount: [String: Int] = [:]
  for call in parsed { actualCount[call.tool, default: 0] += 1 }
  let overConfirmed = confirmationTools.filter { (actualCount[$0] ?? 0) > (expectedCount[$0] ?? 0) }
    .sorted()
  let completed =
    matchedRequired == required && forbiddenCalled.isEmpty && overConfirmed.isEmpty && !hitLimit
  return MultiStepOutcome(
    completed: completed, matched: matchedRequired, required: required,
    firstUnmatched: firstUnmatched, forbiddenCalled: forbiddenCalled, overConfirmed: overConfirmed)
}
