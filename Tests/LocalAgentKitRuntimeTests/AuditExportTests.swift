import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

@Suite struct AuditExportTests {
  @Test func retentionEvictsByRecordingOrderAndReportsDiscardedCount() async throws {
    let policy = AuditRetentionPolicy(maximumEntries: 2, maximumSignatureCharacters: 20)
    let logger = AuditLogger(retention: policy)
    for index in 0..<3 {
      await logger.record(
        entry("tool-\(index)", timestamp: Date(timeIntervalSince1970: Double(100 - index))))
    }
    #expect(await logger.allEntries().map(\.toolName) == ["tool-1", "tool-2"])
    #expect(await logger.discardedEntryCount == 1)
    let snapshot = try object(await logger.exportJSON(exportedAt: Date(timeIntervalSince1970: 200)))
    #expect(snapshot["discardedEntryCount"] as? Int == 1)
    let bounds = try #require(snapshot["retention"] as? [String: Any])
    #expect(bounds["maximumEntries"] as? Int == 2)
    #expect(bounds["maximumSignatureCharacters"] as? Int == 20)
    #expect(AuditRetentionPolicy.default.maximumEntries == 1000)
    #expect(AuditRetentionPolicy.default.maximumSignatureCharacters == 4096)
    #expect(
      AuditRetentionPolicy(maximumEntries: 0, maximumSignatureCharacters: -1).maximumEntries == 1)
    #expect(
      AuditRetentionPolicy(maximumEntries: 0, maximumSignatureCharacters: -1)
        .maximumSignatureCharacters == 1)
  }

  @Test func signatureCapsPreserveGraphemesAndValueSnapshots() async throws {
    let logger = AuditLogger(retention: AuditRetentionPolicy(maximumSignatureCharacters: 2))
    let original = entry("search_contacts", signature: "👩🏽‍💻ab")
    await logger.record(original)
    let retained = try #require(await logger.allEntries().first)
    #expect(retained.argumentsSignature == "👩🏽‍💻a")
    #expect(retained.argumentsWereTruncated)
    #expect(original.argumentsSignature == "👩🏽‍💻ab")
    var copy = retained
    copy.argumentsSignature = "Modified returned copy"
    #expect(await logger.allEntries().first == retained)
    var previouslyTruncated = entry("other", signature: "x")
    previouslyTruncated.argumentsWereTruncated = true
    await logger.record(previouslyTruncated)
    #expect(await logger.allEntries().last?.argumentsWereTruncated == true)
  }

  @Test func exportDefaultsToMetadataWithVersionAndMillisecondDates() async throws {
    let logger = AuditLogger()
    let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let value = AuditEntry(
      id: id, timestamp: Date(timeIntervalSince1970: 100.125), toolName: "search_contacts",
      permission: .sensitive, argumentsSignature: "Jane Doe private query", wasEmpty: true)
    await logger.record(value)
    let data = try await logger.exportJSON(exportedAt: Date(timeIntervalSince1970: 200.5))
    let snapshot = try object(data)
    #expect(snapshot["schemaVersion"] as? Int == 1)
    #expect(snapshot["includesArguments"] as? Bool == false)
    #expect(snapshot["exportedAt"] as? Double == 200500)
    let records = try #require(snapshot["entries"] as? [[String: Any]])
    let record = try #require(records.first)
    #expect(record["id"] as? String == id.uuidString)
    #expect(record["timestamp"] as? Double == 100125)
    #expect(record["permission"] as? String == "sensitive")
    #expect(record["wasEmpty"] as? Bool == true)
    #expect(record["argumentsSignature"] == nil)
    #expect(record["argumentsWereTruncated"] == nil)
    #expect(!String(decoding: data, as: UTF8.self).contains("Jane Doe"))
    #expect(await logger.allEntries().first == value)
    #expect(try await logger.exportJSON(exportedAt: Date(timeIntervalSince1970: 200.5)) == data)
  }

  @Test func argumentExportRequiresOptInAndLabelsTruncation() async throws {
    let logger = AuditLogger(retention: AuditRetentionPolicy(maximumSignatureCharacters: 5))
    await logger.record(entry("search_contacts", signature: "private query"))
    let snapshot = try object(await logger.exportJSON(includeArguments: true))
    #expect(snapshot["includesArguments"] as? Bool == true)
    let record = try #require((snapshot["entries"] as? [[String: Any]])?.first)
    #expect(record["argumentsSignature"] as? String == "priva")
    #expect(record["argumentsWereTruncated"] as? Bool == true)
  }

  @Test func permissionLabelsAreVersionedStringsRatherThanEnumOrdinals() async throws {
    let logger = AuditLogger()
    for permission in ToolPermission.allCases {
      var value = entry("example")
      value.permission = permission
      await logger.record(value)
    }
    let records = try #require(try object(await logger.exportJSON())["entries"] as? [[String: Any]])
    #expect(
      records.compactMap { $0["permission"] as? String } == [
        "none", "readOnly", "userConfirmation", "sensitive", "destructive",
      ])
  }

  @Test func explicitClearKeepsEvidenceOfDiscardedRecordsAndAllowsFutureAppends() async throws {
    let logger = AuditLogger()
    await logger.record(entry("old"))
    await logger.clear()
    #expect(await logger.allEntries().isEmpty)
    #expect(await logger.discardedEntryCount == 1)
    await logger.clear()
    #expect(await logger.discardedEntryCount == 1)
    await logger.record(entry("new"))
    #expect(await logger.allEntries().map(\.toolName) == ["new"])
    #expect(try object(await logger.exportJSON())["discardedEntryCount"] as? Int == 1)
  }

  @Test(arguments: [false, true])
  func invalidDatesAreTypedExportFailuresWithoutDeletingEntries(invalidEntry: Bool) async {
    let logger = AuditLogger()
    let invalid = Date(timeIntervalSince1970: .infinity)
    await logger.record(entry("record", timestamp: invalidEntry ? invalid : Date()))
    await #expect(throws: AgentError.memoryFailure("Could not encode audit export.")) {
      try await logger.exportJSON(exportedAt: invalidEntry ? Date() : invalid)
    }
    #expect(await logger.allEntries().count == 1)
  }

  @Test func concurrentRecordingRetainsAConsistentBoundedSnapshot() async {
    let logger = AuditLogger(retention: AuditRetentionPolicy(maximumEntries: 10))
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<100 { group.addTask { await logger.record(entry("tool-\(index)")) } }
      await group.waitForAll()
    }
    let entries = await logger.allEntries()
    #expect(entries.count == 10)
    #expect(Set(entries.map(\.id)).count == 10)
    #expect(await logger.discardedEntryCount == 90)
  }

  @Test func runtimeExportsRetainedAuditWithoutFullToolResults() async throws {
    let logger = AuditLogger(retention: AuditRetentionPolicy(maximumEntries: 1))
    let tool = MockTool(
      name: "search_contacts",
      schema: ToolSchema(
        parameters: ["query": ToolParameter(.string, description: "name")], required: ["query"]),
      permission: .sensitive, handler: { _ in "SECRET FULL CONTACT RESULT" })
    let workflow = Workflow(
      name: "audit", description: "Read",
      steps: [
        .tool("read", "Read", "search_contacts", ["query": .literal(.string("Jane Doe"))])
      ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: ScriptedModelProvider(responses: [])),
      tools: StaticToolSource([tool]), planner: StateMachinePlanner(workflow: workflow),
      gate: AuditApproveGate(),
      auditLogger: logger)
    _ = try await runtime.run("Find Jane")
    let publicData = try await runtime.exportAuditJSON()
    let privateData = try await runtime.exportAuditJSON(includeArguments: true)
    #expect(!String(decoding: publicData, as: UTF8.self).contains("Jane Doe"))
    #expect(String(decoding: privateData, as: UTF8.self).contains("Jane Doe"))
    #expect(!String(decoding: privateData, as: UTF8.self).contains("SECRET FULL CONTACT RESULT"))
    #expect(await runtime.auditEntries().count == 1)
  }
}

private func entry(_ tool: String, signature: String = "{}", timestamp: Date = Date()) -> AuditEntry
{
  AuditEntry(
    timestamp: timestamp, toolName: tool, permission: .sensitive,
    argumentsSignature: signature, wasEmpty: false)
}
private func object(_ data: Data) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
private struct AuditApproveGate: PermissionGate {
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision { .approved }
}
