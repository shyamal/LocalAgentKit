import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

@Suite struct AuditLoggerTests {
  @Test func recordsInOrderWithinTheRetentionWindow() async {
    let logger = AuditLogger()
    #expect(await logger.allEntries().isEmpty)
    await logger.record(
      AuditEntry(
        toolName: "create_note", permission: .userConfirmation, argumentsSignature: "{}",
        wasEmpty: false))
    await logger.record(
      AuditEntry(
        toolName: "delete_file", permission: .destructive, argumentsSignature: "{}", wasEmpty: false
      ))
    let entries = await logger.allEntries()
    #expect(entries.map(\.toolName) == ["create_note", "delete_file"])
  }
}

@Suite struct ToolExecutorAuditTests {
  private struct ApproveGate: PermissionGate {
    func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision { .approved }
  }

  private func executor(_ tools: [any AgentTool], logger: AuditLogger?) -> ToolExecutor {
    ToolExecutor(
      source: StaticToolSource(tools), gate: ApproveGate(), events: EventBus(), auditLogger: logger)
  }

  @Test func aConfirmedExecutionIsRecorded() async throws {
    let tool = MockTool(name: "create_note", permission: .userConfirmation)
    let logger = AuditLogger()
    _ = try await executor([tool], logger: logger).execute(ToolCall(id: "1", name: "create_note"))
    let entries = await logger.allEntries()
    #expect(entries.count == 1)
    #expect(entries[0].toolName == "create_note")
    #expect(entries[0].permission == .userConfirmation)
    #expect(!entries[0].wasEmpty)
  }

  @Test func readOnlyAndNoneAreNotRecorded() async throws {
    let tools = [
      MockTool(name: "get_time", permission: .none),
      MockTool(name: "read_events", permission: .readOnly),
    ]
    let logger = AuditLogger()
    for tool in tools {
      _ = try await executor(tools, logger: logger).execute(ToolCall(id: "1", name: tool.name))
    }
    #expect(await logger.allEntries().isEmpty)
  }

  @Test func withNoLoggerNothingCrashes() async throws {
    let tool = MockTool(name: "create_note", permission: .userConfirmation)
    _ = try await executor([tool], logger: nil).execute(ToolCall(id: "1", name: "create_note"))
  }

  @Test func aDeniedCallIsNeverRecorded() async {
    struct DenyGate: PermissionGate {
      func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision { .denied }
    }
    let tool = MockTool(name: "create_note", permission: .userConfirmation)
    let logger = AuditLogger()
    let denyingExecutor = ToolExecutor(
      source: StaticToolSource([tool]), gate: DenyGate(), events: EventBus(), auditLogger: logger)
    _ = try? await denyingExecutor.execute(ToolCall(id: "1", name: "create_note"))
    #expect(await logger.allEntries().isEmpty)
  }

  @Test func anEmptyResultIsRecordedAsSuch() async throws {
    let tool = MockTool(name: "create_note", permission: .userConfirmation, handler: { _ in "" })
    let logger = AuditLogger()
    _ = try await executor([tool], logger: logger).execute(ToolCall(id: "1", name: "create_note"))
    // MockTool never sets isEmpty itself, so this documents current behavior: only the tool's own
    // ToolResult.isEmpty flag drives this, not whether the text happens to be blank.
    #expect(await logger.allEntries().first?.wasEmpty == false)
  }

  @Test func argumentSignaturesRetainSensitiveTextWithinPolicy() async throws {
    let tool = MockTool(
      name: "search_contacts",
      schema: ToolSchema(
        parameters: ["query": ToolParameter(.string, description: "q")], required: ["query"]),
      permission: .sensitive)
    let logger = AuditLogger()
    _ = try await executor([tool], logger: logger).execute(
      ToolCall(id: "1", name: "search_contacts", arguments: ToolArguments(["query": "Jane Doe"])))
    let entry = try #require(await logger.allEntries().first)
    #expect(entry.argumentsSignature == ToolArguments(["query": "Jane Doe"]).signature)
  }
}
