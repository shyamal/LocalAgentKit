import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitEvalSupport

@Suite struct ProbeRunnerTests {
  @Test func capturesToolCallsWithoutExecutingOrRepairingThem() async throws {
    let call = ToolCall(
      id: "c", name: "create_reminder", arguments: ToolArguments(["title": "Call plumber"]))
    let model = ScriptedModelProvider(responses: [.toolCall(call)])
    let results = try await ProbeRunner.run(suiteName: "single-tool", model: model, goalID: "st-07")
    let result = try #require(results.first)
    #expect(result.outcome == .toolCalls)
    #expect(result.calls.map(\.name) == ["create_reminder"])
    #expect(result.calls.first?.arguments == call.arguments.values)
    #expect(await model.requests.count == 1)
    #expect(await model.remainingSteps == 0)
    let request = try #require(await model.requests.first)
    #expect(request.tools.count == 8)
    #expect(request.messages.first?.content.contains("2026-09-21T10:00") == true)
    #expect(request.messages.first?.content.contains("UTC") == true)
    let reminder = try #require(request.tools.first { $0.name == "create_reminder" })
    #expect(reminder.permission == .userConfirmation)
    #expect(reminder.schema.required == ["title"])
  }

  @Test func retainsMalformedCallsForLaterScoring() async throws {
    let model = ScriptedModelProvider(responses: [
      .toolCall(ToolCall(id: "bad", name: "unknown_tool", arguments: ToolArguments(["bad": 7])))
    ])
    let result = try await ProbeRunner.run(suiteName: "single-tool", model: model, limit: 1)
    #expect(result.first?.calls.first?.name == "unknown_tool")
    #expect(await model.requests.count == 1)
  }

  @Test func returnedAndThrownRefusalsStayDistinctFromFailuresAndAreNotRetried() async throws {
    let refusal = GuardrailRefusal(explanation: "policy")
    let model = ScriptedModelProvider([
      .respond(.refused(refusal)), .fail(.guardrailRefusal(refusal)),
    ])
    let results = try await ProbeRunner.run(
      suiteName: "refusal", model: model, repetitions: 2, limit: 1)
    #expect(results.map(\.outcome) == [.refused, .refused])
    #expect(results.allSatisfy { $0.text == "policy" && $0.failureKind == nil })
    #expect(await model.requests.count == 2)
  }

  @Test func failureDoesNotDiscardEarlierOrLaterRows() async throws {
    let model = ScriptedModelProvider([
      .respond(.text("before")), .fail(.contextLimitExceeded),
      .respond(.clarification("Which note?")),
    ])
    let results = try await ProbeRunner.run(suiteName: "single-tool", model: model, limit: 3)
    #expect(results.map(\.goalID) == ["st-01", "st-02", "st-03"])
    #expect(results.map(\.outcome) == [.text, .failure, .clarification])
    #expect(results[1].failureKind == "contextLimitExceeded")
  }

  @Test func multipleCallsAndRepetitionsAreRecordedInOrder() async throws {
    let calls = [ToolCall(id: "a", name: "calculate"), ToolCall(id: "b", name: "create_note")]
    let model = ScriptedModelProvider(responses: [.multipleToolCalls(calls), .text("done")])
    let results = try await ProbeRunner.run(
      suiteName: "single-tool", model: model, repetitions: 2, limit: 1)
    #expect(results.map(\.repetition) == [1, 2])
    #expect(results[0].calls.map(\.name) == calls.map(\.name))
    let decoded = try JSONDecoder().decode([ProbeResult].self, from: JSONEncoder().encode(results))
    #expect(decoded[0].calls.map(\.name) == calls.map(\.name))
    #expect(results.allSatisfy { $0.elapsedSeconds >= 0 })
  }

  @Test func deadlineEndsAHungProbe() async throws {
    let results = try await ProbeRunner.run(
      suiteName: "single-tool",
      model: ScriptedModelProvider([.hang]), limit: 1, timeout: .milliseconds(50))
    #expect(results.first?.outcome == .failure)
    #expect(results.first?.failureKind == "timeout")
  }

  @Test func contextIsBudgetedBeforeTheProviderRuns() async throws {
    let model = MockModelProvider(contextWindowTokens: 100)
    let results = try await ProbeRunner.run(suiteName: "single-tool", model: model, limit: 1)
    #expect(results.first?.failureKind == "contextLimitExceeded")
    #expect(await model.requests.isEmpty)
  }

  @Test func badOptionsAreRejectedBeforeCallingTheModel() async {
    let model = ScriptedModelProvider([])
    await #expect(throws: ProbeError.self) {
      try await ProbeRunner.run(suiteName: "multi-step", model: model)
    }
    await #expect(throws: ProbeError.self) {
      try await ProbeRunner.run(suiteName: "single-tool", model: model, repetitions: 0)
    }
    await #expect(throws: ProbeError.self) {
      try await ProbeRunner.run(suiteName: "single-tool", model: model, limit: 0)
    }
    await #expect(throws: ProbeError.self) {
      try await ProbeRunner.run(suiteName: "single-tool", model: model, goalID: "unknown")
    }
    #expect(await model.requests.isEmpty)
  }

  @Test func networkModelsAreRejectedAtConstruction() async {
    let model = MockModelProvider(requiresNetwork: true)
    await #expect(throws: AgentError.self) {
      try await ProbeRunner.run(suiteName: "single-tool", model: model, limit: 1)
    }
    #expect(await model.requests.isEmpty)
  }

  @Test func cancellationStopsTheBatch() async throws {
    let model = ScriptedModelProvider([.hang, .respond(.text("must not run"))])
    let task = Task { try await ProbeRunner.run(suiteName: "single-tool", model: model, limit: 2) }
    // Wait for the first provider call rather than relying on a scheduling delay.
    while await model.requests.isEmpty { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await model.requests.count == 1)
  }

  @Test func enumConstraintsSurviveCatalogConversion() async throws {
    let model = ScriptedModelProvider(responses: [.text("capture")])
    _ = try await ProbeRunner.run(suiteName: "single-tool", model: model, limit: 1)
    let request = try #require(await model.requests.first)
    let files = try #require(request.tools.first { $0.name == "search_files" })
    #expect(
      files.schema.parameters["file_type"]?.allowedValues == [
        "any", "pdf", "image", "document", "spreadsheet",
      ])
  }
}
