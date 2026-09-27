import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

private struct FixedGate: PermissionGate {
  let decision: PermissionDecision
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision { decision }
}

private actor CountingGate: PermissionGate {
  private(set) var asked = 0
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
    asked += 1
    return .approved
  }
}

private let noteSchema = ToolSchema(
  parameters: ["text": ToolParameter(.string, description: "Note text")], required: ["text"])

private func executor(
  _ tools: [any AgentTool], gate: (any PermissionGate)? = nil, bus: EventBus = EventBus()
) -> ToolExecutor {
  ToolExecutor(source: StaticToolSource(tools), gate: gate, events: bus)
}

@Suite struct ToolExecutorTests {
  @Test func readOnlyToolRunsWithoutTheGate() async throws {
    let tool = MockTool(name: "read_events", permission: .readOnly)
    let gate = CountingGate()
    let observation = try await executor([tool], gate: gate)
      .execute(ToolCall(id: "c1", name: "read_events"))
    #expect(observation.result.text == "ok")
    #expect(await gate.asked == 0)
    #expect(await tool.executions.count == 1)
  }

  @Test func resultCarriesTheCallID() async throws {
    let tool = MockTool(name: "add_numbers")
    let observation = try await executor([tool]).execute(
      ToolCall(id: "call-9", name: "add_numbers"))
    #expect(observation.result.callID == "call-9")
    #expect(observation.result.toolName == "add_numbers")
  }

  @Test func unknownToolIsATypedError() async {
    await #expect(throws: AgentError.toolNotFound(name: "nope")) {
      try await executor([]).execute(ToolCall(id: "1", name: "nope"))
    }
  }

  @Test func confirmedToolRunsOnlyAfterApproval() async throws {
    let tool = MockTool(name: "create_note", schema: noteSchema, permission: .userConfirmation)
    let call = ToolCall(id: "1", name: "create_note", arguments: ToolArguments(["text": "hi"]))
    _ = try await executor([tool], gate: FixedGate(decision: .approved)).execute(call)
    #expect(await tool.executions.count == 1)
  }

  @Test func deniedToolNeverExecutes() async {
    let tool = MockTool(name: "create_note", schema: noteSchema, permission: .userConfirmation)
    let call = ToolCall(id: "1", name: "create_note", arguments: ToolArguments(["text": "hi"]))
    await #expect(throws: AgentError.permissionDenied(tool: "create_note")) {
      try await executor([tool], gate: FixedGate(decision: .denied)).execute(call)
    }
    #expect(await tool.executions.isEmpty)
  }

  @Test(arguments: [ToolPermission.userConfirmation, .sensitive, .destructive])
  func withoutAGateEverythingAboveReadOnlyIsDenied(tier: ToolPermission) async {
    let tool = MockTool(name: "delete_file", permission: tier)
    await #expect(throws: AgentError.permissionDenied(tool: "delete_file")) {
      try await executor([tool]).execute(ToolCall(id: "1", name: "delete_file"))
    }
    #expect(await tool.executions.isEmpty)
  }

  /// PRD §19: a schema-valid call that an injected instruction produced is stopped at the gate.
  @Test func schemaValidInjectedCallIsStoppedAtTheGate() async {
    let tool = MockTool(
      name: "delete_file",
      schema: ToolSchema(
        parameters: ["path": ToolParameter(.string, description: "Path")], required: ["path"]),
      permission: .destructive)
    let injected = ToolCall(
      id: "x", name: "delete_file", arguments: ToolArguments(["path": "/Documents/taxes.pdf"]))
    #expect(tool.schema.validate(injected.arguments).isEmpty)
    await #expect(throws: AgentError.permissionDenied(tool: "delete_file")) {
      try await executor([tool], gate: FixedGate(decision: .denied)).execute(injected)
    }
    #expect(await tool.executions.isEmpty)
  }

  @Test func invalidArgumentsStopBeforeTheGateIsAsked() async {
    let tool = MockTool(name: "create_note", schema: noteSchema, permission: .userConfirmation)
    let gate = CountingGate()
    await #expect(
      throws: AgentError.invalidArguments(
        tool: "create_note", violations: [.missingRequired(path: "text")])
    ) {
      try await executor([tool], gate: gate).execute(ToolCall(id: "1", name: "create_note"))
    }
    #expect(await gate.asked == 0)
    #expect(await tool.executions.isEmpty)
  }

  @Test func toolFailureIsTyped() async {
    struct Boom: Error {}
    let tool = MockTool(name: "flaky_tool", handler: { _ in throw Boom() })
    await #expect(throws: AgentError.self) {
      try await executor([tool]).execute(ToolCall(id: "1", name: "flaky_tool"))
    }
  }

  @Test func toolThrowingAgentErrorPassesThrough() async {
    let tool = MockTool(
      name: "flaky_tool", handler: { _ in throw AgentError.retrievalFailure("x") })
    await #expect(throws: AgentError.retrievalFailure("x")) {
      try await executor([tool]).execute(ToolCall(id: "1", name: "flaky_tool"))
    }
  }

  @Test func cancellationBecomesTypedError() async {
    let tool = MockTool(
      name: "slow_tool",
      handler: { _ in
        try await Task.sleep(for: .seconds(60))
        return "late"
      })
    let run = executor([tool])
    let task = Task { try await run.execute(ToolCall(id: "1", name: "slow_tool")) }
    try? await Task.sleep(for: .milliseconds(30))
    task.cancel()
    await #expect(throws: AgentError.cancelled) { try await task.value }
  }

  @Test func eventsFollowTheDocumentedOrder() async throws {
    let bus = EventBus()
    let stream = await bus.subscribe()
    let tool = MockTool(name: "create_note", schema: noteSchema, permission: .userConfirmation)
    let call = ToolCall(id: "1", name: "create_note", arguments: ToolArguments(["text": "hi"]))
    _ = try await executor([tool], gate: FixedGate(decision: .approved), bus: bus).execute(call)
    await bus.finish()
    var names: [String] = []
    for await event in stream {
      switch event {
      case .toolRequested: names.append("requested")
      case .permissionRequired: names.append("permission")
      case .toolStarted: names.append("started")
      case .toolCompleted: names.append("completed")
      case .observationReceived: names.append("observed")
      default: names.append("other")
      }
    }
    #expect(names == ["requested", "permission", "started", "completed", "observed"])
  }
}
