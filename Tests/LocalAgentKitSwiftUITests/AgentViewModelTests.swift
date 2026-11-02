import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitSwiftUI

private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) -> ModelResponse {
  .toolCall(ToolCall(id: "m", name: name, arguments: ToolArguments(arguments)))
}
private func choice(_ action: String) -> ModelResponse {
  call("choose_next_action", ["action": .string(action)])
}

@MainActor
private func makeViewModel(
  _ model: ScriptedModelProvider, tools: [any AgentTool] = [], gate: (any PermissionGate)? = nil
) throws -> AgentViewModel {
  let runtime = try AgentRuntime(
    configuration: AgentConfiguration(model: model), tools: StaticToolSource(tools), gate: gate)
  return AgentViewModel(runtime: runtime)
}

/// Polls `condition` on the main actor until it is true or a short budget runs out — the view
/// model's state changes as its background event-consuming task delivers events, not
/// synchronously with `send`.
@MainActor
private func waitUntil(
  _ condition: @MainActor () -> Bool, timeout: Duration = .seconds(2)
) async {
  let deadline = ContinuousClock.now + timeout
  while !condition(), ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(5))
  }
}

@Suite struct AgentViewModelTests {
  @Test @MainActor func thermalStatusIsBridgedToObservableState() async throws {
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: MockModelProvider()), tools: StaticToolSource([]),
      thermalStateSource: MockThermalStateSource(.critical))
    let viewModel = AgentViewModel(runtime: runtime)
    await Task.yield()
    viewModel.send("Run")
    await waitUntil { viewModel.thermalStatus?.state == .critical && viewModel.lastFailure != nil }
    #expect(viewModel.thermalStatus?.allowsNewWork == false)
    #expect(viewModel.lastFailure == AgentError.thermalPressureTooHigh.description)
    #expect(viewModel.state == .idle)
  }
  @Test @MainActor func startsIdleWithNoTurns() throws {
    let viewModel = try makeViewModel(ScriptedModelProvider([]))
    #expect(viewModel.state == .idle)
    #expect(viewModel.turns.isEmpty)
    #expect(!viewModel.isRunning)
  }

  @Test @MainActor func sendAppendsTheUserTurnImmediatelyAndGoesToRunning() throws {
    let viewModel = try makeViewModel(ScriptedModelProvider([.hang]))
    viewModel.send("What meetings do I have?")
    #expect(viewModel.turns.count == 1)
    #expect(viewModel.turns[0].role == .user)
    #expect(viewModel.turns[0].text == "What meetings do I have?")
    #expect(viewModel.isRunning)
  }

  @Test @MainActor func sendWhileRunningIsIgnored() throws {
    let viewModel = try makeViewModel(ScriptedModelProvider([.hang]))
    viewModel.send("First")
    viewModel.send("Second")
    #expect(viewModel.turns.count == 1)
  }

  @Test @MainActor func aCompletedRunAppendsTheAssistantTurnAndReturnsToIdle() async throws {
    let model = ScriptedModelProvider(responses: [choice("finish"), .text("Two meetings today.")])
    let viewModel = try makeViewModel(model)
    viewModel.send("What meetings do I have?")
    await waitUntil { viewModel.state == .idle && viewModel.turns.count == 2 }
    #expect(viewModel.turns[1].role == .assistant)
    #expect(viewModel.turns[1].text == "Two meetings today.")
    #expect(!viewModel.isRunning)
  }

  @Test @MainActor func toolActivityIsTrackedAcrossStartAndCompletion() async throws {
    let tool = MockTool(name: "get_time", permission: .none, handler: { _ in "10:00" })
    let model = ScriptedModelProvider(responses: [
      choice("get_time"), choice("finish"), .text("It's 10."),
    ])
    let viewModel = try makeViewModel(model, tools: [tool])
    viewModel.send("What time is it?")
    await waitUntil { !viewModel.toolActivity.isEmpty }
    #expect(viewModel.toolActivity.first?.toolName == "get_time")
    #expect(viewModel.toolActivity.first?.text == "10:00")
    await waitUntil { viewModel.state == .idle }
    #expect(viewModel.activeTool == nil)
  }

  @Test @MainActor func permissionRequiredSuspendsAndApprovingResumes() async throws {
    let tool = MockTool(
      name: "create_note", permission: .userConfirmation, handler: { _ in "saved" })
    let model = ScriptedModelProvider(responses: [
      choice("create_note"), choice("finish"), .text("Saved it."),
    ])
    let viewModel = try makeViewModel(model, tools: [tool])
    viewModel.send("Save a note")

    await waitUntil {
      if case .awaitingPermission = viewModel.state { true } else { false }
    }
    guard case .awaitingPermission(let call) = viewModel.state else {
      Issue.record("expected awaitingPermission")
      return
    }
    #expect(call.name == "create_note")
    #expect(await tool.executions.isEmpty)

    viewModel.approvePermission()
    await waitUntil { viewModel.state == .idle }
    #expect(await tool.executions.count == 1)
    #expect(viewModel.turns.last?.text == "Saved it.")
  }

  @Test @MainActor func denyingPermissionEndsTheRunWithAFailure() async throws {
    let tool = MockTool(name: "create_note", permission: .userConfirmation)
    let model = ScriptedModelProvider(responses: [choice("create_note")])
    let viewModel = try makeViewModel(model, tools: [tool])
    viewModel.send("Save a note")

    await waitUntil {
      if case .awaitingPermission = viewModel.state { true } else { false }
    }
    viewModel.denyPermission()
    await waitUntil { viewModel.state == .idle }
    #expect(await tool.executions.isEmpty)
    #expect(viewModel.lastFailure != nil)
  }

  @Test @MainActor func approvingWithNothingPendingDoesNothing() throws {
    let viewModel = try makeViewModel(ScriptedModelProvider([]))
    viewModel.approvePermission()
    #expect(viewModel.state == .idle)
  }

  @Test @MainActor func clarificationIsAppendedAsAnAssistantTurnAndAnsweringResumes() async throws {
    let model = ScriptedModelProvider(responses: [
      choice("finish"), .clarification("Which day?"), choice("finish"),
      .text("Booked for Tuesday."),
    ])
    let viewModel = try makeViewModel(model)
    viewModel.send("Book a meeting")

    await waitUntil {
      if case .awaitingClarification = viewModel.state { true } else { false }
    }
    #expect(viewModel.turns.last?.role == .assistant)
    #expect(viewModel.turns.last?.text == "Which day?")

    viewModel.answerClarification("Tuesday")
    await waitUntil { viewModel.state == .idle && viewModel.turns.count == 4 }
    #expect(viewModel.turns[2].role == .user)
    #expect(viewModel.turns[2].text == "Tuesday")
    #expect(viewModel.turns[3].text == "Booked for Tuesday.")
  }

  @Test @MainActor func aGuardrailRefusalAppendsAnAssistantTurnAndSetsLastFailure() async throws {
    let refusal = GuardrailRefusal(explanation: "I can't help with medical dosing.")
    let model = ScriptedModelProvider(responses: [.refused(refusal)])
    let viewModel = try makeViewModel(model)
    viewModel.send("risky question")
    await waitUntil { viewModel.state == .idle && viewModel.turns.count == 2 }
    #expect(viewModel.turns[1].role == .assistant)
    #expect(viewModel.turns[1].text == "I can't help with medical dosing.")
    #expect(viewModel.lastFailure == "I can't help with medical dosing.")
  }

  @Test @MainActor func anErrorSetsLastFailureAndReturnsToIdleWithoutAnAssistantTurn() async throws
  {
    let model = ScriptedModelProvider([.fail(.modelUnavailable(reason: "boom"))])
    let viewModel = try makeViewModel(model)
    viewModel.send("go")
    await waitUntil { viewModel.state == .idle }
    #expect(viewModel.turns.count == 1)  // only the user's turn
    #expect(viewModel.lastFailure != nil)
  }

  @Test @MainActor func sendClearsThePreviousFailure() async throws {
    let model = ScriptedModelProvider([
      .fail(.modelUnavailable(reason: "boom")), .respond(choice("finish")), .respond(.text("ok")),
    ])
    let viewModel = try makeViewModel(model)
    viewModel.send("first")
    await waitUntil { viewModel.lastFailure != nil }
    viewModel.send("second")
    #expect(viewModel.lastFailure == nil)
  }

  @Test @MainActor func contextUtilizationIsTracked() async throws {
    let model = ScriptedModelProvider(responses: [choice("finish"), .text("ok")])
    let viewModel = try makeViewModel(model)
    viewModel.send("hi")
    await waitUntil { viewModel.contextUtilization != nil }
    #expect((viewModel.contextUtilization?.limitTokens ?? 0) > 0)
  }

  @Test @MainActor func cancelEndsARunningTurn() async throws {
    let viewModel = try makeViewModel(ScriptedModelProvider([.hang]))
    viewModel.send("go")
    #expect(viewModel.isRunning)
    viewModel.cancel()
    await waitUntil { viewModel.state == .idle }
    #expect(viewModel.lastFailure != nil)
  }
}
