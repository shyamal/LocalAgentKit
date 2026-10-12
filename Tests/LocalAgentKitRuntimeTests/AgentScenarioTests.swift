import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

private func action(_ name: String) -> ModelResponse {
  .toolCall(
    ToolCall(
      id: "choice", name: "choose_next_action",
      arguments: ToolArguments(["action": .string(name)])))
}

/// PRD §18: each fixture declares a goal, requested/executed tools, result, iteration bound,
/// and permission expectations. Scripts verify runtime behavior, not real model accuracy.
private struct Scenario: Sendable {
  let goal: String
  let tool: String
  let permission: ToolPermission
  let approved: Bool
  let expectedExecutions: Int
  let result: String
  let maxIterations: Int

  static let cases: [Scenario] = [
    Scenario(
      goal: "What meetings do I have tomorrow?", tool: "read_calendar",
      permission: .readOnly, approved: false, expectedExecutions: 1,
      result: "Budget review at 9am.", maxIterations: 2),
    Scenario(
      goal: "Find my budget review notes.", tool: "search_documents",
      permission: .readOnly, approved: false, expectedExecutions: 1,
      result: "Review the quarterly forecast.", maxIterations: 2),
    Scenario(
      goal: "Save the preparation checklist.", tool: "create_note",
      permission: .userConfirmation, approved: true, expectedExecutions: 1,
      result: "Checklist saved.", maxIterations: 2),
    Scenario(
      goal: "Save the preparation checklist.", tool: "create_note",
      permission: .userConfirmation, approved: false, expectedExecutions: 0,
      result: "The note was not saved.", maxIterations: 2),
    Scenario(
      goal: "Delete the old checklist.", tool: "delete_note",
      permission: .destructive, approved: false, expectedExecutions: 0,
      result: "The note was not deleted.", maxIterations: 2),
  ]
}

private actor ScenarioGate: PermissionGate {
  let approved: Bool
  private(set) var tools: [String] = []
  init(approved: Bool) { self.approved = approved }
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
    tools.append(call.name)
    return approved ? .approved : .denied
  }
}

@Suite struct AgentScenarioTests {
  @Test(arguments: Scenario.cases)
  fileprivate func goalMatchesItsExecutionContract(_ scenario: Scenario) async throws {
    let tool = MockTool(
      name: scenario.tool, permission: scenario.permission,
      handler: { _ in "fixture output" })
    let gate = ScenarioGate(approved: scenario.approved)
    let denied = scenario.permission > .readOnly && !scenario.approved
    let script: [ModelResponse] =
      denied
      ? [action(scenario.tool)]
      : [action(scenario.tool), action("finish"), .text(scenario.result)]
    let model = ScriptedModelProvider(responses: script)
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(
        model: model,
        limits: ExecutionLimits(maxIterations: scenario.maxIterations)),
      tools: StaticToolSource([tool]), gate: gate)
    let events = await runtime.events()
    if denied {
      await #expect(throws: AgentError.permissionDenied(tool: scenario.tool)) {
        try await runtime.run(scenario.goal)
      }
    } else {
      let response = try await runtime.run(scenario.goal)
      #expect(response.text == scenario.result)
      #expect(response.iterations <= scenario.maxIterations)
    }
    await runtime.finishEvents()
    var requested: [String] = []
    var completed: [String] = []
    for await event in events {
      if case .toolRequested(let call) = event { requested.append(call.name) }
      if case .toolCompleted(let result) = event { completed.append(result.toolName) }
    }
    #expect(requested == [scenario.tool])
    #expect(await tool.executions.count == scenario.expectedExecutions)
    #expect(completed == (scenario.expectedExecutions == 1 ? [scenario.tool] : []))
    let needsPermission = scenario.permission > .readOnly
    #expect(await gate.tools == (needsPermission ? [scenario.tool] : []))
    #expect(await model.remainingSteps == 0)
  }

  /// The demo's four-turn memory contract, using deterministic stand-ins for device tools.
  /// This cannot establish on-device planning quality or the rendering of a permission sheet.
  @Test func fourTurnsCarryNotesIntoReasoningAndConfirmBeforeSaving() async throws {
    let calendar = MockTool(
      name: "read_calendar", permission: .readOnly,
      handler: { _ in "Budget review tomorrow at 9am." })
    let notes = MockTool(
      name: "search_documents", permission: .readOnly,
      handler: { _ in "Bring the quarterly forecast." })
    let save = MockTool(name: "create_note", permission: .userConfirmation)
    let model = ScriptedModelProvider(responses: [
      action("read_calendar"), action("finish"), .text("Budget review tomorrow at 9am."),
      action("search_documents"), action("finish"), .text("Bring the quarterly forecast."),
      action("finish"), .text("Checklist: review the quarterly forecast before 9am."),
      action("create_note"), action("finish"), .text("Saved."),
    ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model),
      tools: StaticToolSource([calendar, notes, save]), memory: ConversationMemory())
    _ = try await runtime.run("What meetings do I have tomorrow?")
    _ = try await runtime.run("Find my notes related to those meetings.")
    let checklist = try await runtime.run("Create a preparation checklist.")
    #expect(checklist.toolCallCount == 0)
    let reasoningPrompt = await model.requests[6].messages.last?.content ?? ""
    #expect(reasoningPrompt.contains("Budget review tomorrow at 9am."))
    #expect(reasoningPrompt.contains("Bring the quarterly forecast."))
    let events = await runtime.events()
    let saving = Task { try await runtime.run("Save that as a note.") }
    var pending: ToolCall?
    for await event in events {
      if case .permissionRequired(let call) = event {
        pending = call
        break
      }
      if case .error = event { break }
    }
    guard let pending else {
      await runtime.cancelCurrentRun()
      _ = try? await saving.value
      Issue.record("saving must request permission")
      return
    }
    #expect(pending.name == "create_note")
    #expect(await save.executions.isEmpty)
    #expect(await runtime.resolvePermission(callID: pending.id, approved: true))
    #expect(try await saving.value.text == "Saved.")
    #expect(await save.executions.count == 1)
    let savingPrompt = await model.requests[8].messages.last?.content ?? ""
    #expect(savingPrompt.contains(checklist.text))
    #expect(await calendar.executions.count == 1)
    #expect(await notes.executions.count == 1)
    #expect(await model.remainingSteps == 0)
  }
}
