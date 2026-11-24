import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitEvalSupport

private func referenceCalls(_ id: String) -> [MultiStepCall] {
  func call(_ name: String, _ arguments: [String: JSONValue]) -> MultiStepCall {
    MultiStepCall(name: name, arguments: arguments, completed: true, output: nil)
  }
  switch id {
  case "mx-01":
    return [
      call("search_notes", ["query": "K7"]),
      call("search_documents", ["query": "PACK-K7"]),
      call("calculate", ["expression": "18*24"]),
      call("create_note", ["title": "K7 packing", "body": "432 units at Dock C"]),
      call("create_reminder", ["title": "Send K7 summary: 432 units", "due": "2026-09-22T09:00"]),
    ]
  case "mx-02":
    return [
      call("search_notes", ["query": "workshop"]),
      call("search_documents", ["query": "Cedar"]),
      call("search_contacts", ["query": "Mira Chen"]),
      call("create_note", ["title": "Workshop", "body": "Cedar, 14 seats, Mira Chen, 555-0174"]),
    ]
  case "mx-03":
    return [
      call("search_notes", ["query": "equipment"]),
      call("search_documents", ["query": "equipment limit"]),
      call("create_note", ["title": "Equipment over limit", "body": "420 exceeds 300"]),
    ]
  case "mx-04":
    return [
      call("search_notes", ["query": "equipment"]),
      call("search_documents", ["query": "equipment limit"]),
    ]
  case "mx-05":
    return [
      call("search_notes", ["query": "staging"]),
      call("search_documents", ["query": "staging checklist"]),
      call("create_note", ["title": "Staging", "body": "RAVEN-6: verify pump"]),
    ]
  case "mx-06":
    return [
      call("search_documents", ["query": "onboarding"]),
      call("search_notes", ["query": "escort"]),
      call("create_note", ["title": "Onboarding", "body": "Badge desk 4; escort Jules"]),
    ]
  case "mx-07":
    return [
      call("search_notes", ["query": "Q8"]),
      call("search_documents", ["query": "RESTART-Q8"]),
      call("create_note", ["title": "Q8 restart", "body": "Require blue gate before restarting"]),
      call("create_reminder", ["title": "Check Q8 blue gate", "due": "2026-09-22T16:00"]),
    ]
  case "mx-08":
    return [
      call("search_files", ["query": "Sprint Delta", "file_type": "pdf"]),
      call("search_documents", ["query": "Sprint Delta"]),
      call("calculate", ["expression": "72/6"]),
      call("create_note", ["title": "Sprint Delta", "body": "12 days per person"]),
    ]
  default: return []
  }
}

private func expandedGoal(_ id: String) throws -> SuiteLoader.Suite.Goal {
  try #require(SuiteLoader.suite(named: "multi-step-extended").goals?.first { $0.id == id })
}
private func scriptedCalls(_ calls: [MultiStepCall]) -> [ModelResponse] {
  calls.flatMap { call in
    [
      ModelResponse.toolCall(
        ToolCall(
          id: "action", name: "choose_next_action",
          arguments: ToolArguments(["action": .string(call.name)]))),
      .toolCall(
        ToolCall(
          id: "arguments", name: "provide_\(call.name)_arguments",
          arguments: ToolArguments(call.arguments))),
    ]
  } + [
    .toolCall(
      ToolCall(
        id: "finish", name: "choose_next_action",
        arguments: ToolArguments(["action": "finish"]))), .text("Finished synthetic task."),
  ]
}

@Suite struct ExpandedMultiStepTests {
  @Test func supplementalSuiteHasSeparateIdentityAndLeavesBaselineUnchanged() throws {
    let suite = try SuiteLoader.suite(named: "multi-step-extended")
    #expect(suite.name == "m5-expanded-multi-step" && suite.version == 1)
    #expect(suite.task == "M5-08" && suite.goalCount == 8)
    #expect(try SuiteLoader.suite(named: "multi-step").goalCount == 10)
    #expect(!SuiteLoader.phase0Names.contains("multi-step-extended"))
  }

  @Test(arguments: (1...8).map { String(format: "mx-%02d", $0) })
  func referenceTracesMatchButEveryMissingRequiredStepFails(_ id: String) async throws {
    let goal = try expandedGoal(id)
    let tools = try SuiteLoader.tools()
    let calls = referenceCalls(id)
    let full = try await MultiStepScorer.score(
      goal: goal, calls: calls, tools: tools, answered: true)
    #expect(full.completed && full.extraCalls == 0 && full.schemaInvalidCalls == 0)
    for index in calls.indices {
      var missing = calls
      missing.remove(at: index)
      let score = try await MultiStepScorer.score(
        goal: goal, calls: missing, tools: tools, answered: true)
      #expect(!score.completed)
    }
  }

  @Test func independentFanInReadsMaySwapButFinalWriteMustWait() async throws {
    var calls = referenceCalls("mx-02")
    calls.swapAt(1, 2)
    #expect(
      try await MultiStepScorer.score(
        goal: expandedGoal("mx-02"), calls: calls,
        tools: SuiteLoader.tools(), answered: true
      ).completed)
    calls.swapAt(2, 3)
    #expect(
      try await !MultiStepScorer.score(
        goal: expandedGoal("mx-02"), calls: calls,
        tools: SuiteLoader.tools(), answered: true
      ).completed)
  }

  @Test(arguments: ["mx-01", "mx-02", "mx-03", "mx-05", "mx-06", "mx-07", "mx-08"])
  func wrongGroundedWriteContentFails(_ id: String) async throws {
    var calls = referenceCalls(id)
    let index = try #require(calls.firstIndex { $0.name == "create_note" })
    let original = calls[index]
    var arguments = original.arguments
    arguments["body"] = "Invented content without fixture facts"
    calls[index] = MultiStepCall(
      name: original.name, arguments: arguments, completed: true, output: nil)
    let score = try await MultiStepScorer.score(
      goal: expandedGoal(id), calls: calls,
      tools: SuiteLoader.tools(), answered: true)
    #expect(!score.completed && score.schemaInvalidCalls == 0)
  }

  @Test(arguments: ["mx-04", "mx-06"])
  func forbiddenActionsFailEvenIfAllRequiredStepsMatch(_ id: String) async throws {
    var calls = referenceCalls(id)
    let tool = id == "mx-04" ? "create_note" : "create_reminder"
    let arguments: [String: JSONValue] =
      tool == "create_note"
      ? ["title": "Unwanted", "body": "Unwanted"] : ["title": "Unwanted"]
    calls.append(MultiStepCall(name: tool, arguments: arguments, completed: true, output: nil))
    let score = try await MultiStepScorer.score(
      goal: expandedGoal(id), calls: calls,
      tools: SuiteLoader.tools(), answered: true)
    #expect(!score.completed && score.forbiddenCalls == [tool])
  }

  @Test(arguments: (1...8).map { String(format: "mx-%02d", $0) })
  func syntheticRunnerExecutesEachContractWithoutOraclePromptLeakage(_ id: String) async throws {
    let model = ScriptedModelProvider(responses: scriptedCalls(referenceCalls(id)))
    let result = try #require(
      try await MultiStepRunner.run(
        model: model, goalID: id,
        suiteName: "multi-step-extended"
      ).first)
    #expect(result.score.completed && result.stopReason == "answer")
    #expect(result.calls.count == referenceCalls(id).count)
    #expect(result.calls.allSatisfy { $0.completed })
    let requests = await model.requests
    let firstPrompt = requests.first?.messages.map(\.content).joined(separator: "\n") ?? ""
    #expect(!firstPrompt.contains("groundedIn") && !firstPrompt.contains("stepsMatched"))
    if id == "mx-05" {
      #expect(result.calls.first?.output == "No results found.")
      #expect(result.calls[1].output?.contains("RAVEN-6") == true)
      #expect(!firstPrompt.contains("RAVEN-6"))
    }
    if id == "mx-01" || id == "mx-07" { #expect(result.confirmationsApproved == 2) }
    #expect(await model.remainingSteps == 0)
  }

  @Test func unsupportedSuiteIsRejectedBeforeGeneration() async {
    let model = MockModelProvider()
    await #expect(throws: ProbeError.self) {
      try await MultiStepRunner.run(model: model, suiteName: "refusal")
    }
    #expect(await model.requests.isEmpty)
  }
  @Test func optionalComparisonCanRunWithoutAuthorizingAWrite() async throws {
    var calls = referenceCalls("mx-04")
    calls.append(
      MultiStepCall(
        name: "calculate", arguments: ["expression": "180-300"],
        completed: true, output: "-120"))
    let score = try await MultiStepScorer.score(
      goal: expandedGoal("mx-04"), calls: calls,
      tools: SuiteLoader.tools(), answered: true)
    #expect(score.completed && score.extraCalls == 0 && score.stepsExpected == 2)
  }

  @Test func repeatedConfirmedWriteCannotEarnCompletion() async throws {
    var calls = referenceCalls("mx-07")
    calls.append(calls[2])
    let score = try await MultiStepScorer.score(
      goal: expandedGoal("mx-07"), calls: calls,
      tools: SuiteLoader.tools(), answered: true)
    #expect(!score.completed && score.overConfirmedTools == ["create_note"])
  }

}
