import Foundation
import LocalAgentKitCore
import SwiftData
import Testing

@testable import LocalAgentKitProviders

@MainActor
@Suite struct ConversationMigrationTests {
  @Test func unplannedV1CheckpointLoadsWithoutChangingPayloadBytes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("conversation.store")
    let id = UUID()
    let payload = try checkpoint(id)
    try writeV1(id: id, payload: payload, to: url)
    let store = try SwiftDataConversationStore(storage: .file(url))
    #expect(
      try await store.load(conversationID: id)?.messages == [
        ModelMessage(role: .user, content: "Prepare"),
        ModelMessage(role: .assistant, content: "Checklist — 準備 📝"),
      ])
    let schema = Schema(versionedSchema: ConversationSchemaV1.self)
    let container = try ModelContainer(
      for: schema, migrationPlan: ConversationMigrationPlan.self,
      configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    let context = ModelContext(container)
    let records = try context.fetch(FetchDescriptor<ConversationSchemaV1.StoredConversation>())
    #expect(records.count == 1)
    #expect(records.first?.payload == payload)
  }

  @Test func upgradedCheckpointRetainsPayloadAndRejectsOlderSdk() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("upgrade-conversation.store")
    let id = UUID()
    let payload = try checkpoint(id)
    try writeV1(id: id, payload: payload, to: url)
    try verifyV2(id: id, payload: payload, url: url, initialize: true)
    #expect(throws: AgentError.memoryFailure("Unsupported memory store version or schema family."))
    {
      try SwiftDataConversationStore(storage: .file(url))
    }
    try verifyV2(id: id, payload: payload, url: url, initialize: false)
  }

  @Test func wrongStoreFamiliesAreRejectedWithoutDeletingRecords() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("memory.store")
    let other = directory.appendingPathComponent("conversation.store")
    let memory = Memory(content: "Retain this memory")
    let store = try SwiftDataMemoryStore(storage: .file(url))
    try await store.save(memory)
    #expect(throws: AgentError.memoryFailure("Unsupported memory store version or schema family."))
    {
      try SwiftDataConversationStore(storage: .file(url))
    }
    #expect(try await store.search(MemoryQuery(text: "")) == [memory])
    let id = UUID()
    let payload = try checkpoint(id)
    try writeV1(id: id, payload: payload, to: other)
    #expect(throws: AgentError.memoryFailure("Unsupported memory store version or schema family."))
    {
      try SwiftDataMemoryStore(storage: .file(other))
    }
    let conversation = try SwiftDataConversationStore(storage: .file(other))
    #expect(
      try await conversation.load(conversationID: id)?.messages.last?.content == "Checklist — 準備 📝")
  }

  private func checkpoint(_ id: UUID) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "version": 1, "conversationID": id.uuidString,
        "entries": [
          ["role": "user", "content": "Prepare"],
          ["role": "assistant", "content": "Checklist — 準備 📝"],
        ],
      ], options: [.sortedKeys])
  }

  private func writeV1(id: UUID, payload: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let schema = Schema(versionedSchema: ConversationSchemaV1.self)
    let container = try ModelContainer(
      for: schema,
      configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    let context = ModelContext(container)
    context.autosaveEnabled = false
    context.insert(ConversationSchemaV1.StoredConversation(id: id, payload: payload))
    try context.save()
  }

  private func verifyV2(id: UUID, payload: Data, url: URL, initialize: Bool) throws {
    let schema = Schema(versionedSchema: FixtureConversationV2.self)
    let container = try ModelContainer(
      for: schema, migrationPlan: FixtureConversationMigration.self,
      configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    let context = ModelContext(container)
    let records = try context.fetch(FetchDescriptor<FixtureConversationV2.StoredConversation>())
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.id == id)
    #expect(record.payload == payload)
    if initialize {
      #expect(record.label == nil)
      record.label = "future conversation label"
      try context.save()
    } else {
      #expect(record.label == "future conversation label")
    }
  }
}

private enum FixtureConversationV2: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
  static var models: [any PersistentModel.Type] { [StoredConversation.self] }
  @Model final class StoredConversation {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var label: String?
    init(id: UUID, payload: Data, label: String? = nil) {
      self.id = id
      self.payload = payload
      self.label = label
    }
  }
}

private enum FixtureConversationMigration: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] {
    ConversationMigrationPlan.schemas + [FixtureConversationV2.self]
  }
  static var stages: [MigrationStage] {
    ConversationMigrationPlan.stages + [
      .lightweight(fromVersion: ConversationSchemaV1.self, toVersion: FixtureConversationV2.self)
    ]
  }
}
