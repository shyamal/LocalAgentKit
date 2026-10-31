import Foundation

/// Continuous, scoped evidence for PRD §44 M5. Fixture tools cannot establish real-tool success.
public struct M5Assessment: Codable, Sendable {
  public struct Counts: Codable, Sendable {
    public let attempts: Int
    public let executed: Int
    public let groundedSuccesses: Int
    public let executionRate: Double?
    public let groundedSuccessRate: Double?
    init(attempts: Int, executed: Int, groundedSuccesses: Int) {
      self.attempts = attempts
      self.executed = executed
      self.groundedSuccesses = groundedSuccesses
      executionRate = attempts == 0 ? nil : Double(executed) / Double(attempts)
      groundedSuccessRate = attempts == 0 ? nil : Double(groundedSuccesses) / Double(attempts)
    }
  }
  public enum Verdict: String, Codable, Sendable {
    case synthetic, incomplete, inconclusive, insufficientCoverage, belowTarget, fixtureEvidenceOnly
  }
  public let metric: String
  public let scope: String
  public let target: String
  public let verdict: Verdict
  public let realToolTargetVerified: Bool
  public let protocolComplete: Bool
  public let expectedTrials: Int
  public let observedTrials: Int
  public let completedGoals: Int
  public let expectedRequiredSteps: Int
  public let requiredSteps: Int
  public let matchedRequiredSteps: Int
  public let counts: Counts
  public let byTool: [String: Counts]
  public let missingGroundedToolCoverage: [String]
  public let notes: [String]

  /// Replays catalog and goal matchers against raw calls; saved score aggregates are not trusted.
  /// Protocol: all bundled multi-step goals, three repetitions each, StateMachinePlanner open mode.
  public static func assess(
    _ results: [MultiStepResult], synthetic: Bool, repetitions: Int, timeoutSeconds: Double = 60
  ) async throws -> M5Assessment {
    guard (1...100).contains(repetitions), timeoutSeconds.isFinite, timeoutSeconds > 0,
      timeoutSeconds <= 3600
    else {
      throw ProbeError.invalidOptions("Invalid M5 repetition count.")
    }
    let suite = try SuiteLoader.suite(named: "multi-step")
    let goals = suite.goals ?? []
    let catalog = try SuiteLoader.tools()
    let known = Dictionary(uniqueKeysWithValues: goals.map { ($0.id, $0) })
    var seen: Set<String> = []
    var counts: [String: Counts] = Dictionary(
      uniqueKeysWithValues: catalog.map {
        ($0.name, Counts(attempts: 0, executed: 0, groundedSuccesses: 0))
      })
    var completedGoals = 0
    var requiredSteps = 0
    var matchedSteps = 0
    for row in results {
      try Task.checkCancellation()
      guard let goal = known[row.goalID], (1...repetitions).contains(row.repetition),
        [
          "answer", "clarification", "limit", "timeout", "refused", "loop", "modelUnavailable",
          "error",
        ].contains(row.stopReason),
        row.elapsedSeconds.isFinite, row.elapsedSeconds >= 0,
        seen.insert("\(row.goalID)#\(row.repetition)").inserted
      else {
        throw ProbeError.invalidOptions("Unknown, duplicate or invalid M5 trial.")
      }
      let score = try await MultiStepScorer.score(
        goal: goal, calls: row.calls, tools: catalog,
        answered: row.stopReason == "answer" && row.answer != nil)
      completedGoals += score.completed ? 1 : 0
      requiredSteps += score.stepsExpected
      matchedSteps += score.stepsMatched
      let matched = Set(score.matchedCallIndices.values)
      for (index, call) in row.calls.enumerated() {
        let previous = counts[call.name] ?? Counts(attempts: 0, executed: 0, groundedSuccesses: 0)
        counts[call.name] = Counts(
          attempts: previous.attempts + 1,
          executed: previous.executed + (call.completed ? 1 : 0),
          groundedSuccesses: previous.groundedSuccesses + (matched.contains(index) ? 1 : 0))
      }
    }
    let total = Counts(
      attempts: counts.values.reduce(0) { $0 + $1.attempts },
      executed: counts.values.reduce(0) { $0 + $1.executed },
      groundedSuccesses: counts.values.reduce(0) { $0 + $1.groundedSuccesses })
    let expected = goals.count * 3
    let complete = repetitions == 3 && timeoutSeconds == 60 && seen.count == expected
    let missing = catalog.map(\.name).filter { counts[$0]?.groundedSuccesses == 0 }.sorted()
    var verdict = verdict(synthetic: synthetic, complete: complete, counts: total)
    if verdict == .fixtureEvidenceOnly && (matchedSteps < requiredSteps || !missing.isEmpty) {
      verdict = .insufficientCoverage
    }
    return M5Assessment(
      metric: "M5", scope: "fixture-tools/stateMachine-open",
      target: "Tool execution success >95% for supported built-in tools",
      verdict: verdict, realToolTargetVerified: false, protocolComplete: complete,
      expectedTrials: expected, observedTrials: results.count, completedGoals: completedGoals,
      expectedRequiredSteps: goals.reduce(0) {
        $0 + ($1.steps ?? []).filter { $0.optional != true }.count
      } * 3,
      requiredSteps: requiredSteps, matchedRequiredSteps: matchedSteps, counts: total,
      byTool: counts, missingGroundedToolCoverage: missing,
      notes: [
        "Execution means the fixture call completed; grounded success also requires valid, goal-matching arguments and dependency order.",
        "Unemitted required calls remain visible in required-step and per-tool coverage; no calls means an unknown rate, never 100%.",
        "This suite uses fixture tools (plus real calculator arithmetic), not the actual device tool backends. No verdict establishes the real-tool M5 target.",
        "Completion, refusal, model and runtime failures remain in the source report; they are not excluded to improve a rate.",
      ])
  }
  static func verdict(synthetic: Bool, complete: Bool, counts: Counts) -> Verdict {
    if synthetic { return .synthetic }
    if !complete { return .incomplete }
    if counts.attempts == 0 { return .inconclusive }
    return Double(counts.groundedSuccesses) / Double(counts.attempts) <= 0.95
      ? .belowTarget : .fixtureEvidenceOnly
  }

}

/// Offline replay of an existing schema-3 report, retaining the run's OS and model identity.
public struct M5Report: Encodable, Sendable {
  public let schemaVersion = 1
  public let operatingSystem: String
  public let model: String
  public let synthetic: Bool
  public let measuredAt: Date
  public let repetitions: Int
  public let timeoutSeconds: Double
  public let suite: String
  public let suiteVersion: Int
  public let assessment: M5Assessment

  public static func from(_ data: Data) async throws -> M5Report {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let saved = try decoder.decode(Saved.self, from: data)
    let metadata = try SuiteLoader.suite(named: "multi-step")
    guard saved.schemaVersion == 3, saved.mode == "agent-run", saved.planner == "stateMachine-open",
      saved.suite == metadata.name, saved.suiteVersion == metadata.version,
      saved.context == metadata.context, !saved.model.isEmpty, !saved.operatingSystem.isEmpty
    else { throw ProbeError.invalidOptions("M5 report protocol mismatch.") }
    let assessment = try await M5Assessment.assess(
      saved.results, synthetic: saved.synthetic,
      repetitions: saved.repetitions, timeoutSeconds: saved.timeoutSeconds)
    return M5Report(
      operatingSystem: saved.operatingSystem, model: saved.model,
      synthetic: saved.synthetic, measuredAt: saved.createdAt, repetitions: saved.repetitions,
      timeoutSeconds: saved.timeoutSeconds, suite: saved.suite,
      suiteVersion: saved.suiteVersion, assessment: assessment)
  }
  private struct Saved: Decodable {
    let schemaVersion: Int
    let mode: String
    let planner: String
    let suite: String
    let suiteVersion: Int
    let context: SuiteLoader.Suite.Context?
    let model: String
    let synthetic: Bool
    let operatingSystem: String
    let createdAt: Date
    let repetitions: Int
    let timeoutSeconds: Double
    let results: [MultiStepResult]
  }
}
