import LocalAgentKitCore

/// One requested call, with completed execution distinguished from rejected/failed attempts.
public struct MultiStepCall: Codable, Sendable {
  public let name: String
  public let arguments: [String: JSONValue]
  public let completed: Bool
  public let output: String?
}

/// Completion-contract diagnostics. Optional steps are excluded from the required-step count.
public struct MultiStepScore: Codable, Sendable {
  public let completed: Bool
  public let stepsMatched: Int
  public let stepsExpected: Int
  public let firstUnmatchedStep: String?
  public let matchedCallIndices: [String: Int]
  public let forbiddenCalls: [String]
  public let overConfirmedTools: [String]
  public let extraCalls: Int
  public let schemaInvalidCalls: Int
}

/// Implements the fixture's dependency-order completion contract; semantic matches require
/// completed, catalog-valid calls. An unmatched optional dependency does not block a step.
public enum MultiStepScorer {
  public static func score(
    goal: SuiteLoader.Suite.Goal, calls: [MultiStepCall],
    tools: [SuiteLoader.Tool], answered: Bool
  ) async throws -> MultiStepScore {
    let steps = goal.steps ?? []
    guard !steps.isEmpty, (goal.maxIterations ?? 0) > 0 else {
      throw ProbeError.invalidOptions("Goal \(goal.id) has no steps or call bound.")
    }
    let knownTools = Set(tools.map(\.name))
    var seen: Set<String> = []
    for step in steps {
      guard !step.id.isEmpty, knownTools.contains(step.tool), seen.insert(step.id).inserted,
        !step.dependsOn.contains(step.id),
        step.dependsOn.allSatisfy({ seen.contains($0) })
      else {
        throw ProbeError.invalidOptions("Invalid dependency order in \(goal.id).")
      }
      for matcher in step.arguments.values { try matcher.validate() }
    }
    let scorer = try ToolValidityScorer(tools: tools)
    let validity = try scorer.score([
      ProbeResult(
        goalID: goal.id, repetition: 1, outcome: .toolCalls,
        text: nil, calls: calls.map { .init(name: $0.name, arguments: $0.arguments) },
        failureKind: nil, error: nil, elapsedSeconds: 0)
    ])[0].calls
    var indices: [String: Int] = [:]
    var used: Set<Int> = []
    var firstUnmatched: String?
    var matched = 0
    let required = steps.filter { $0.optional != true }.count
    for step in steps {
      let blocked = step.dependsOn.contains { dependency in
        indices[dependency] == nil && steps.first(where: { $0.id == dependency })?.optional != true
      }
      let after = step.dependsOn.compactMap { indices[$0] }.max() ?? -1
      var hit: Int?
      if !blocked {
        for index in calls.indices
        where index > after && !used.contains(index)
          && calls[index].name == step.tool && calls[index].completed && validity[index].valid
        {
          if try await GoalMatcher.all(step.arguments, arguments: calls[index].arguments) {
            hit = index
            break
          }
        }
      }
      if let hit {
        indices[step.id] = hit
        used.insert(hit)
        if step.optional != true { matched += 1 }
      } else if step.optional != true && firstUnmatched == nil {
        firstUnmatched = step.id
      }
    }
    let forbidden = calls.map(\.name).filter { (goal.forbidden ?? []).contains($0) }
    var expectedCounts: [String: Int] = [:]
    for step in steps { expectedCounts[step.tool, default: 0] += 1 }
    let overConfirmed = tools.filter(\.needsConfirmation).map(\.name).filter { name in
      calls.filter { $0.name == name }.count > (expectedCounts[name] ?? 0)
    }.sorted()
    let withinLimit = calls.count <= (goal.maxIterations ?? 0)
    return MultiStepScore(
      completed: answered && matched == required && forbidden.isEmpty
        && overConfirmed.isEmpty && withinLimit, stepsMatched: matched, stepsExpected: required,
      firstUnmatchedStep: firstUnmatched, matchedCallIndices: indices, forbiddenCalls: forbidden,
      overConfirmedTools: overConfirmed, extraCalls: calls.count - used.count,
      schemaInvalidCalls: validity.filter { !$0.valid }.count)
  }
}
