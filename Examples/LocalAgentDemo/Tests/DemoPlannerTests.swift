import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

@testable import DemoSetup

@Suite struct DemoPlannerTests {
  @Test(arguments: [false, true])
  func calendarDisplaysToolFactsAndQueryDayWithoutModelRewriting(empty: Bool) async throws {
    let tool = FixtureCalendar(empty: empty)
    let model = ScriptedModelProvider(responses: [])
    let now = try #require(ISO8601DateFormatter().date(from: "2026-11-03T15:00:00Z"))
    let zone = try #require(TimeZone(identifier: "Asia/Colombo"))
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model),
      tools: StaticToolSource([tool]), planner: DemoPlanner(), timeZone: zone, now: { now })
    let response = try await runtime.run("What meetings do I have tomorrow?")
    #expect(response.toolCallCount == 1)
    #expect(response.text.contains("2026-11-04 (Asia/Colombo)"))
    #expect(response.text.contains(empty ? "No events found." : "Budget review"))
    #expect(await model.requests.isEmpty)
    if !empty { #expect(response.text.contains("10:00 – 11:00")) }
    let call = try #require(await tool.executions.first)
    #expect(call.string("start") == "2026-11-03T18:30:00Z")
    #expect(call.string("end") == "2026-11-04T18:30:00Z")
  }

  @Test func tomorrowRangeUsesLocalDayAcrossDaylightSavingChange() async throws {
    let tool = FixtureCalendar(empty: true)
    let model = ScriptedModelProvider(responses: [])
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z"))
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model),
      tools: StaticToolSource([tool]), planner: DemoPlanner(), timeZone: zone, now: { now })
    _ = try await runtime.run("What meetings do I have tomorrow?")
    let call = try #require(await tool.executions.first)
    let start = try #require(call.string("start").flatMap { ISO8601DateFormatter().date(from: $0) })
    let end = try #require(call.string("end").flatMap { ISO8601DateFormatter().date(from: $0) })
    #expect(end.timeIntervalSince(start) == 25 * 60 * 60)
  }

  @Test func savingWithoutACompletedChecklistDoesNotWrite() async throws {
    let save = MockTool(name: "create_note", permission: .userConfirmation)
    let model = ScriptedModelProvider(responses: [.text("Create a checklist first.")])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([save]),
      planner: DemoPlanner())
    let response = try await runtime.run("Save that as a note.")
    #expect(response.toolCallCount == 0)
    #expect(await save.executions.isEmpty)
    #expect(await model.requests.count == 1)
  }

  @Test(arguments: [true, false])
  func savingUsesTheExactChecklistAndHonorsPermission(approve: Bool) async throws {
    let save = MockTool(
      name: "create_note",
      schema: ToolSchema(
        parameters: [
          "title": ToolParameter(.string, description: "Title"),
          "body": ToolParameter(.string, description: "Body"),
        ], required: ["title", "body"]), permission: .userConfirmation,
      handler: { _ in "Saved note Preparation checklist." })
    let checklist = String(repeating: "- Ask Priya for the headcount spreadsheet.\n", count: 20)
    let model = ScriptedModelProvider(responses: [])
    let gate = RecordingGate(approve: approve)
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([save]),
      planner: DemoPlanner(), gate: gate)
    do {
      _ = try await runtime.run(
        "Save that as a note.",
        conversation: [
          ModelMessage(role: .user, content: "Create a preparation checklist."),
          ModelMessage(role: .assistant, content: checklist),
        ])
      #expect(approve)
    } catch let error as AgentError {
      #expect(!approve)
      guard case .permissionDenied = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
    let calls = await gate.calls
    #expect(calls.count == 1)
    #expect(calls.first?.arguments.string("body") == checklist)
    #expect(await save.executions.count == (approve ? 1 : 0))
    if approve { #expect(await save.executions.first?.string("body") == checklist) }
    #expect(await model.requests.isEmpty)
  }

  @Test func checklistAnswersFromHistoryWithoutSelectingOrExecutingTools() async throws {
    let search = MockTool(name: "search_documents", permission: .readOnly)
    let save = MockTool(name: "create_note", permission: .userConfirmation)
    let model = ScriptedModelProvider(responses: [
      .text("- Ask Priya for the spreadsheet.\n- Update headcount figures.")
    ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([search, save]),
      planner: DemoPlanner())
    let response = try await runtime.run(
      "Create a preparation checklist.",
      conversation: [
        ModelMessage(role: .assistant, content: "Budget review tomorrow at 10am."),
        ModelMessage(
          role: .assistant,
          content: String(repeating: "Retrieved note context. ", count: 20)
            + "Notes: ask Priya for the spreadsheet and update headcount figures."),
      ])
    #expect(response.toolCallCount == 0)
    #expect(await search.executions.isEmpty)
    #expect(await save.executions.isEmpty)
    let requests = await model.requests
    #expect(requests.count == 1)
    #expect(requests.first?.purpose == .answer)
    #expect(requests.first?.tools.isEmpty == true)
    #expect(requests.first?.messages.contains(where: { $0.content.contains("Priya") }) == true)
    #expect(
      requests.first?.messages.contains(where: { $0.content.contains("Budget review") }) == true)
  }

  @Test func emptySearchFinishesWithoutRetrying() async throws {
    let model = ScriptedModelProvider(responses: [
      .toolCall(
        ToolCall(
          id: "args", name: "provide_search_documents_arguments",
          arguments: ToolArguments(["query": .string("Budget review")])))
    ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([EmptySearch()]),
      planner: DemoPlanner())
    let response = try await runtime.run("“Find my notes related to those meetings.”")
    #expect(response.toolCallCount == 1)
    #expect(response.text.contains("No results found."))
    let requests = await model.requests
    #expect(requests.count == 1)
  }

  @Test func relatedNotesSearchExecutesOnceAndUsesMeetingHistory() async throws {
    let search = MockTool(
      name: "search_documents",
      schema: ToolSchema(
        parameters: ["query": ToolParameter(.string, description: "Search terms")],
        required: ["query"]),
      permission: .readOnly, handler: { _ in "Budget review prep: ask Priya for the spreadsheet." })
    let model = ScriptedModelProvider(responses: [
      .toolCall(
        ToolCall(
          id: "args", name: "provide_search_documents_arguments",
          arguments: ToolArguments(["query": .string("Budget review")])))
    ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model, limits: ExecutionLimits(maxIterations: 2)),
      tools: StaticToolSource([search]),
      planner: DemoPlanner())
    let response = try await runtime.run(
      "Find my notes related to those meetings.",
      conversation: [
        ModelMessage(role: .assistant, content: "Tomorrow: Budget review at 10am.")
      ])
    #expect(response.toolCallCount == 1)
    #expect(response.iterations == 2)
    #expect(await search.executions == [ToolArguments(["query": .string("Budget review")])])
    let requests = await model.requests
    #expect(requests.count == 1)
    #expect(requests.first?.messages.last?.content.contains("Budget review at 10am") == true)
    #expect(response.text.contains("Note search results for “Budget review”"))
    #expect(response.text.contains("Budget review prep: ask Priya for the spreadsheet."))
  }
}

private struct EmptySearch: AgentTool {
  let name = "search_documents"
  let description = "Search fixture notes."
  let permission = ToolPermission.readOnly
  let isParallelSafe = true
  let isCancellable = true
  let schema = ToolSchema(
    parameters: ["query": ToolParameter(.string, description: "Search terms")], required: ["query"])

  func execute(arguments: ToolArguments) async throws -> ToolResult {
    ToolResult(callID: "", toolName: name, text: "No results found.", isEmpty: true)
  }
}

private actor RecordingGate: PermissionGate {
  let approve: Bool
  var calls: [ToolCall] = []
  init(approve: Bool) { self.approve = approve }
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
    calls.append(call)
    return approve ? .approved : .denied
  }
}

private actor FixtureCalendar: AgentTool {
  let name = "list_calendar_events"
  let description = "Read calendar fixtures."
  let permission = ToolPermission.readOnly
  let isParallelSafe = true
  let isCancellable = true
  let schema = ToolSchema(
    parameters: [
      "start": ToolParameter(.string, description: "Start"),
      "end": ToolParameter(.string, description: "End"),
    ], required: ["start", "end"])
  let empty: Bool
  var executions: [ToolArguments] = []
  init(empty: Bool) { self.empty = empty }
  func execute(arguments: ToolArguments) async throws -> ToolResult {
    executions.append(arguments)
    return ToolResult(
      callID: "", toolName: name,
      text: empty ? "No events found." : "Budget review at 10am",
      structured: empty
        ? nil
        : .array([
          .object([
            "title": .string("Budget review"), "start": .string("2026-11-04T04:30:00Z"),
            "end": .string("2026-11-04T05:30:00Z"),
          ])
        ]), isEmpty: empty)
  }
}
