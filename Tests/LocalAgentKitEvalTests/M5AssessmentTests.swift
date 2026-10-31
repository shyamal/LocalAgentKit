import Foundation
import Testing

@testable import LocalAgentKitEvalSupport

private func m5Calls() -> [MultiStepCall] {
  [
    MultiStepCall(
      name: "search_notes", arguments: ["query": .string("lunch receipt")], completed: true,
      output: nil),
    MultiStepCall(
      name: "calculate", arguments: ["expression": .string("212.4 * 0.15")], completed: true,
      output: nil),
    MultiStepCall(
      name: "create_note",
      arguments: ["title": .string("tip"), "body": .string("The tip is 31.86.")], completed: true,
      output: nil),
  ]
}
private func m5Row(_ goal: String = "ms-02", repetition: Int = 1, calls: [MultiStepCall] = [])
  -> MultiStepResult
{
  MultiStepResult(
    goalID: goal, repetition: repetition, calls: calls,
    score: MultiStepScore(
      completed: true, stepsMatched: 999, stepsExpected: 999,
      firstUnmatchedStep: nil, matchedCallIndices: [:], forbiddenCalls: [], overConfirmedTools: [],
      extraCalls: 0, schemaInvalidCalls: 0),
    answer: "Done", stopReason: "answer", error: nil, runtimeIterations: 1,
    confirmationsApproved: 0, elapsedSeconds: 1)
}
private func fullM5Rows() throws -> [MultiStepResult] {
  try (SuiteLoader.suite(named: "multi-step").goals ?? []).flatMap { goal in
    (1...3).map { m5Row(goal.id, repetition: $0) }
  }
}
private func m5SavedReport(_ rows: [MultiStepResult], repetitions: Int = 1) throws -> [String: Any]
{
  let suite = try SuiteLoader.suite(named: "multi-step")
  return [
    "schemaVersion": 3, "mode": "agent-run", "planner": "stateMachine-open",
    "suite": suite.name, "suiteVersion": suite.version,
    "context": try JSONSerialization.jsonObject(with: JSONEncoder().encode(suite.context)),
    "model": "foundation", "synthetic": false, "operatingSystem": "OS test",
    "createdAt": "2026-10-31T00:00:00Z", "repetitions": repetitions, "timeoutSeconds": 60,
    "results": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)),
  ]
}

@Suite struct M5AssessmentTests {
  @Test func fullProtocolWithoutCallsIsUnknownNotPerfect() async throws {
    let value = try await M5Assessment.assess(fullM5Rows(), synthetic: false, repetitions: 3)
    #expect(value.protocolComplete && value.observedTrials == 30)
    #expect(value.verdict == .inconclusive && value.counts.groundedSuccessRate == nil)
    #expect(value.counts.executionRate == nil && !value.realToolTargetVerified)
    #expect(value.missingGroundedToolCoverage.count == 8 && value.completedGoals == 0)
  }

  @Test func groundedExecutionIsRescoredAndPartialTrialsCannotPass() async throws {
    let value = try await M5Assessment.assess(
      [m5Row(calls: m5Calls())], synthetic: false, repetitions: 1)
    #expect(value.verdict == .incomplete && !value.protocolComplete)
    #expect(
      value.counts.attempts == 3 && value.counts.executed == 3
        && value.counts.groundedSuccesses == 3)
    #expect(value.counts.groundedSuccessRate == 1 && value.completedGoals == 1)
    #expect(value.requiredSteps == 3 && value.matchedRequiredSteps == 3)
    #expect(value.byTool["calculate"]?.groundedSuccesses == 1)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
    let counts = try #require(json?["counts"] as? [String: Any])
    #expect(counts["executionRate"] as? Double == 1)
  }

  @Test func successfulFixtureExecutionDoesNotMeanGroundedArguments() async throws {
    var calls = m5Calls()
    calls[1] = MultiStepCall(
      name: "calculate", arguments: ["expression": .string("1")], completed: true, output: "1")
    let value = try await M5Assessment.assess(
      [m5Row(calls: calls)], synthetic: false, repetitions: 1)
    #expect(value.counts.executionRate == 1 && value.counts.groundedSuccesses == 1)
    #expect(value.counts.groundedSuccessRate == 1.0 / 3.0)
    #expect(value.completedGoals == 0)
  }

  @Test func failuresAndExtraCallsStayInTheDenominator() async throws {
    var calls = m5Calls()
    calls[0] = MultiStepCall(
      name: "search_notes", arguments: ["query": .string("lunch receipt")], completed: false,
      output: nil)
    calls.append(MultiStepCall(name: "unknown_tool", arguments: [:], completed: false, output: nil))
    let value = try await M5Assessment.assess(
      [m5Row(calls: calls)], synthetic: false, repetitions: 1)
    #expect(
      value.counts.attempts == 4 && value.counts.executed == 2
        && value.counts.groundedSuccesses == 0)
    #expect(value.byTool["unknown_tool"]?.attempts == 1)
  }

  @Test func strictThresholdNeverDeclaresFixtureEvidenceARealPass() {
    let boundary = M5Assessment.Counts(attempts: 20, executed: 20, groundedSuccesses: 19)
    #expect(
      M5Assessment.verdict(synthetic: false, complete: true, counts: boundary) == .belowTarget)
    let above = M5Assessment.Counts(attempts: 20, executed: 20, groundedSuccesses: 20)
    #expect(
      M5Assessment.verdict(synthetic: false, complete: true, counts: above) == .fixtureEvidenceOnly)
    #expect(M5Assessment.verdict(synthetic: true, complete: true, counts: above) == .synthetic)
  }

  @Test func perfectEmittedCallRateCannotHideOmittedRequiredActions() async throws {
    let rows = try fullM5Rows().map { row in
      row.goalID == "ms-02" ? m5Row(row.goalID, repetition: row.repetition, calls: m5Calls()) : row
    }
    let value = try await M5Assessment.assess(rows, synthetic: false, repetitions: 3)
    #expect(value.protocolComplete && value.counts.groundedSuccessRate == 1)
    #expect(value.verdict == .insufficientCoverage && !value.realToolTargetVerified)
    #expect(value.expectedRequiredSteps == value.requiredSteps)
    #expect(value.matchedRequiredSteps < value.requiredSteps)
  }

  @Test func nonstandardTimeoutCannotQualifyAsTheFullProtocol() async throws {
    let value = try await M5Assessment.assess(
      fullM5Rows(), synthetic: false, repetitions: 3, timeoutSeconds: 45)
    #expect(!value.protocolComplete && value.verdict == .incomplete)
  }

  @Test func invalidTrialsAreRejected() async throws {
    for rows in [[m5Row("unknown")], [m5Row(), m5Row()], [m5Row(repetition: 4)]] {
      await #expect(throws: ProbeError.self) {
        try await M5Assessment.assess(rows, synthetic: false, repetitions: 3)
      }
    }
  }

  @Test func replayRetainsIdentityAndRejectsAnotherPlanner() async throws {
    var saved = try m5SavedReport([m5Row(calls: m5Calls())])
    let report = try await M5Report.from(JSONSerialization.data(withJSONObject: saved))
    #expect(report.operatingSystem == "OS test" && report.model == "foundation")
    #expect(report.assessment.verdict == .incomplete && !report.synthetic)
    saved["planner"] = "another-planner"
    let data = try JSONSerialization.data(withJSONObject: saved)
    await #expect(throws: ProbeError.self) { try await M5Report.from(data) }
  }
}
