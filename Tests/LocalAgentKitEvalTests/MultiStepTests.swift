import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitEvalSupport

private func action(_ tool: String) -> ModelResponse {
  .toolCall(
    ToolCall(
      id: "m", name: "choose_next_action", arguments: ToolArguments(["action": .string(tool)])))
}
private func arguments(_ tool: String, _ values: [String: JSONValue]) -> ModelResponse {
  .toolCall(ToolCall(id: "m", name: "provide_\(tool)_arguments", arguments: ToolArguments(values)))
}
private func completedCall(_ name: String, _ arguments: [String: JSONValue], completed: Bool = true)
  -> MultiStepCall
{
  MultiStepCall(name: name, arguments: arguments, completed: completed, output: nil)
}
private func tipCalls() -> [MultiStepCall] {
  [
    completedCall("search_notes", ["query": "lunch receipt"]),
    completedCall("calculate", ["expression": "212.4 * 0.15"]),
    completedCall("create_note", ["title": "tip", "body": "The tip is 31.86."]),
  ]
}
private func goal(_ id: String) throws -> SuiteLoader.Suite.Goal {
  try #require(SuiteLoader.suite(named: "multi-step").goals?.first { $0.id == id })
}

@Suite struct MultiStepScorerTests {
  @Test func aCompleteGroundedChainMatchesInOrder() async throws {
    let score = try await MultiStepScorer.score(
      goal: goal("ms-02"), calls: tipCalls(),
      tools: SuiteLoader.tools(), answered: true)
    #expect(score.completed)
    #expect(score.stepsMatched == 3 && score.stepsExpected == 3)
    #expect(score.matchedCallIndices == ["find": 0, "tip": 1, "save": 2])
    #expect(score.extraCalls == 0 && score.schemaInvalidCalls == 0)
  }

  @Test func dependencyOrderMissingDependenciesAndWrongGroundedValuesFail() async throws {
    let calls = tipCalls()
    for invalid in [
      [calls[1], calls[0], calls[2]], Array(calls.dropFirst()),
      [calls[0], completedCall("calculate", ["expression": "10"]), calls[2]],
    ] {
      let score = try await MultiStepScorer.score(
        goal: goal("ms-02"), calls: invalid,
        tools: SuiteLoader.tools(), answered: true)
      #expect(!score.completed)
      #expect(score.stepsMatched < 3)
    }
  }

  @Test func rejectedCallsAndFalseAnswersCannotEarnCompletion() async throws {
    var calls = tipCalls()
    calls[1] = completedCall("calculate", ["expression": "212.4 * 0.15"], completed: false)
    #expect(
      try await !MultiStepScorer.score(
        goal: goal("ms-02"), calls: calls,
        tools: SuiteLoader.tools(), answered: true
      ).completed)
    #expect(
      try await !MultiStepScorer.score(
        goal: goal("ms-02"), calls: tipCalls(),
        tools: SuiteLoader.tools(), answered: false
      ).completed)
    calls = tipCalls()
    calls[2] = completedCall("create_note", ["body": "31.86"])
    let invalid = try await MultiStepScorer.score(
      goal: goal("ms-02"), calls: calls,
      tools: SuiteLoader.tools(), answered: true)
    #expect(!invalid.completed && invalid.schemaInvalidCalls == 1)
  }

  @Test func extraReadCallsAreAllowedButRepeatedConfirmedCallsAreNot() async throws {
    var calls = tipCalls()
    calls.append(completedCall("search_files", ["query": "receipt"]))
    let extra = try await MultiStepScorer.score(
      goal: goal("ms-02"), calls: calls,
      tools: SuiteLoader.tools(), answered: true)
    #expect(extra.completed && extra.extraCalls == 1)
    calls.append(tipCalls()[2])
    let repeated = try await MultiStepScorer.score(
      goal: goal("ms-02"), calls: calls,
      tools: SuiteLoader.tools(), answered: true)
    #expect(!repeated.completed && repeated.overConfirmedTools == ["create_note"])
  }

  @Test func optionalCalculationCanBeOmittedButForbiddenNoteFails() async throws {
    var calls = [
      completedCall("search_notes", ["query": "phone plan"]),
      completedCall("search_documents", ["query": "Unlimited Lite plan"]),
    ]
    let optional = try await MultiStepScorer.score(
      goal: goal("ms-10"), calls: calls,
      tools: SuiteLoader.tools(), answered: true)
    #expect(optional.completed && optional.stepsExpected == 2)
    calls.append(completedCall("create_note", ["title": "plan", "body": "change"]))
    let forbidden = try await MultiStepScorer.score(
      goal: goal("ms-10"), calls: calls,
      tools: SuiteLoader.tools(), answered: true)
    #expect(!forbidden.completed && forbidden.forbiddenCalls == ["create_note"])
  }

  @Test func exceedingTheFixtureCallLimitFails() async throws {
    let calls =
      tipCalls() + (0..<4).map { _ in completedCall("search_files", ["query": "receipt"]) }
    #expect(
      try await !MultiStepScorer.score(
        goal: goal("ms-02"), calls: calls,
        tools: SuiteLoader.tools(), answered: true
      ).completed)
  }
}

@Suite struct MultiStepRunnerTests {
  @Test func fixturesReachTheDefaultPlannerAndConfirmedWritesAreSynthetic() async throws {
    let model = ScriptedModelProvider(responses: [
      action("search_notes"), arguments("search_notes", ["query": "lunch receipt"]),
      action("calculate"), arguments("calculate", ["expression": "212.4 * 0.15"]),
      action("create_note"),
      arguments("create_note", ["title": "tip", "body": "The tip is 31.86."]),
      action("finish"), .text("Saved the tip."),
    ])
    let row = try #require(try await MultiStepRunner.run(model: model, goalID: "ms-02").first)
    #expect(row.score.completed && row.score.stepsMatched == 3)
    #expect(row.confirmationsApproved == 1)
    #expect(row.calls.allSatisfy { $0.completed })
    #expect(row.calls[0].output?.contains("212.40") == true)
    #expect(row.calls[1].output == "31.86")
    #expect(row.runtimeIterations == 4 && row.stopReason == "answer")
    let requests = await model.requests
    let zone = try #require(TimeZone(identifier: "UTC"))
    #expect(requests[0].messages.first?.content.contains("10:00 (\(zone.identifier))") == true)
    #expect(requests[0].messages.last?.content.contains("212.40") == false)
    #expect(requests[2].messages.last?.content.contains("212.40") == true)
    #expect(await model.remainingSteps == 0)
  }

  @Test func stoppingEarlyIsNotCompletion() async throws {
    let model = ScriptedModelProvider(responses: [action("finish"), .text("Already done.")])
    let row = try #require(try await MultiStepRunner.run(model: model, limit: 1).first)
    #expect(!row.score.completed && row.calls.isEmpty && row.score.stepsMatched == 0)
  }

  @Test func unattendedClarificationStopsRatherThanHanging() async throws {
    let model = ScriptedModelProvider(responses: [action("finish"), .clarification("Which note?")])
    let row = try #require(try await MultiStepRunner.run(model: model, limit: 1).first)
    #expect(row.stopReason == "clarification" && !row.score.completed)
  }

  @Test func refusalIsTerminalAndNeverRetried() async throws {
    let model = ScriptedModelProvider(responses: [.refused(GuardrailRefusal(explanation: "policy"))]
    )
    let row = try #require(try await MultiStepRunner.run(model: model, limit: 1).first)
    #expect(row.stopReason == "refused" && !row.score.completed)
    #expect(await model.requests.count == 1)
  }

  @Test func externalCancellationStopsTheBatchAndClosesTheObserver() async throws {
    let model = ScriptedModelProvider([.hang])
    let task = Task { try await MultiStepRunner.run(model: model, limit: 2) }
    while await model.requests.isEmpty { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await model.requests.count == 1)
  }

  @Test func invalidSelectionDoesNotCallTheProvider() async {
    let model = ScriptedModelProvider([])
    await #expect(throws: ProbeError.self) { try await MultiStepRunner.run(model: model, limit: 0) }
    await #expect(throws: ProbeError.self) {
      try await MultiStepRunner.run(model: model, goalID: "unknown")
    }
    #expect(await model.requests.isEmpty)
  }

  @Test func deadlineStopsAHungRun() async throws {
    let row = try #require(
      try await MultiStepRunner.run(
        model: ScriptedModelProvider([.hang]),
        limit: 1, timeout: .milliseconds(50)
      ).first)
    #expect(row.stopReason == "timeout" && !row.score.completed)
  }
}

@Suite struct GoalMatcherTests {
  private func matcher(_ json: String) throws -> GoalMatcher {
    try JSONDecoder().decode(GoalMatcher.self, from: Data(json.utf8))
  }
  @Test func arithmeticAlternativesToleranceAndMalformedExpressions() async throws {
    let m = try matcher(#"{"match":"evaluatesTo","values":[7,-7],"tolerance":0.01}"#)
    #expect(try await m.matches("49-42"))
    #expect(try await m.matches("42-49"))
    #expect(try await !m.matches("abc"))
    #expect(try await !m.matches("1/0"))
  }
  @Test func datesAreStrictAndCompareInUTC() async throws {
    let m = try matcher(#"{"match":"datetime","value":"2026-09-23T19:00","toleranceMinutes":120}"#)
    #expect(try await m.matches("2026-09-23T20:59"))
    #expect(try await !m.matches("2026-09-23T21:01"))
    #expect(try await !m.matches("2026-02-30T19:00"))
    let day = try matcher(#"{"match":"date","value":"2026-09-23","toleranceDays":0}"#)
    #expect(try await day.matches("2026-09-23T19:00"))
  }
  @Test func malformedMatcherSettingsCannotProduceVacuousMatches() async {
    for json in [
      #"{"match":"containsAll"}"#, #"{"match":"exact"}"#,
      #"{"match":"evaluatesTo","value":7,"tolerance":-1}"#,
    ] {
      await #expect(throws: ProbeError.self) { try await matcher(json).matches("anything") }
    }
  }

  @Test func stringAndAbsentMatchers() async throws {
    #expect(try await matcher(#"{"match":"exact","value":"abc"}"#).matches(" abc "))
    #expect(try await matcher(#"{"match":"caseInsensitive","value":"ABC"}"#).matches("abc"))
    #expect(
      try await matcher(#"{"match":"containsAll","terms":["tip","31.86"]}"#).matches("TIP 31.86"))
    #expect(try await matcher(#"{"match":"containsAny","terms":["tip","cost"]}"#).matches("COST"))
    #expect(try await matcher(#"{"match":"absent"}"#).matches(nil))
    #expect(throws: DecodingError.self) { try matcher(#"{"match":"invented"}"#) }
  }
}
