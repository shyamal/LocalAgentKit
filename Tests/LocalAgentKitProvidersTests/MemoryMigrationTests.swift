import Foundation
import LocalAgentKitCore
import SwiftData
import Testing

@testable import LocalAgentKitProviders

@MainActor
@Suite struct MemoryMigrationTests {
  @Test func existingUnplannedV1FileOpensWithoutChangingValues() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("memory.store")
    let original = Memory(
      content: "Budget review — 準備 📝", metadata: ["unknown-app-key": "preserve", "empty": ""])
    let semantic = try SemanticMemory(kind: .preference, content: "Use metric units").memory()
    let episodic = try EpisodicMemory(
      kind: .action, content: "Saved checklist", occurredAt: Date(timeIntervalSince1970: 100)
    ).memory()
    try writeV1([original, semantic, episodic], to: url)
    let store = try SwiftDataMemoryStore(storage: .file(url))
    #expect(
      Set(try await store.search(MemoryQuery(text: "", limit: 20)))
        == Set([original, semantic, episodic]))
    #expect(try await store.searchSemantic(text: "").first == SemanticMemory(memory: semantic))
    #expect(try await store.searchEpisodic(text: "").first == EpisodicMemory(memory: episodic))
  }

  @Test func lightweightUpgradePreservesValuesAndAddsOptionalField() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("upgrade.store")
    let original = try SemanticMemory(
      kind: .fact, content: "Budget review owner is Priya", metadata: ["source": "profile"]
    ).memory()
    try writeV1([original], to: url)
    try verifyV2(original, at: url, setSource: true)
    // An older SDK must fail closed instead of resetting or downgrading the newer file.
    do {
      _ = try SwiftDataMemoryStore(storage: .file(url))
      Issue.record("Expected an unsupported-version failure")
    } catch let error as AgentError {
      guard case .memoryFailure = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
    // Reopening with the upgraded schema confirms the failure did not delete the data.
    try verifyV2(original, at: url)
  }

  @Test func failedCustomUpgradeLeavesOriginalFileReadable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("failed-upgrade.store")
    let memory = Memory(content: "Keep the original", metadata: ["source": "user"])
    try writeV1([memory], to: url)
    let schema = Schema(versionedSchema: FixtureMemoryV2.self)
    #expect(throws: (any Error).self) {
      try ModelContainer(
        for: schema, migrationPlan: FailingMemoryMigration.self,
        configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    }
    let original = try SwiftDataMemoryStore(storage: .file(url))
    #expect(try await original.search(MemoryQuery(text: "")) == [memory])
  }

  private func writeV1(_ memories: [Memory], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let schema = Schema(versionedSchema: MemorySchemaV1.self)
    let container = try ModelContainer(
      for: schema,
      configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    let context = ModelContext(container)
    context.autosaveEnabled = false
    for memory in memories { context.insert(try MemorySchemaV1.StoredMemory(memory: memory)) }
    try context.save()
  }

  private func verifyV2(_ memory: Memory, at url: URL, setSource: Bool = false) throws {
    let schema = Schema(versionedSchema: FixtureMemoryV2.self)
    let container = try ModelContainer(
      for: schema, migrationPlan: FixtureMemoryMigration.self,
      configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    let context = ModelContext(container)
    let records = try context.fetch(FetchDescriptor<FixtureMemoryV2.StoredMemory>())
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.id == memory.id)
    #expect(record.content == memory.content)
    #expect(record.createdAt == memory.createdAt)
    #expect(
      try JSONDecoder().decode([String: String].self, from: record.metadataJSON) == memory.metadata)
    if setSource {
      #expect(record.source == nil)
      record.source = "future-only data"
      try context.save()
    } else {
      #expect(record.source == "future-only data")
    }
  }
}

// Test-only future storage shape: exercise the upgrade path without shipping unused columns.
private enum FixtureMemoryV2: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
  static var models: [any PersistentModel.Type] { [StoredMemory.self] }
  @Model final class StoredMemory {
    @Attribute(.unique) var id: UUID
    var content: String
    var createdAt: Date
    var metadataJSON: Data
    var source: String?
    init(id: UUID, content: String, createdAt: Date, metadataJSON: Data, source: String? = nil) {
      self.id = id
      self.content = content
      self.createdAt = createdAt
      self.metadataJSON = metadataJSON
      self.source = source
    }
  }
}

private enum FixtureMemoryMigration: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] {
    MemoryMigrationPlan.schemas + [FixtureMemoryV2.self]
  }
  static var stages: [MigrationStage] {
    MemoryMigrationPlan.stages + [
      .lightweight(fromVersion: MemorySchemaV1.self, toVersion: FixtureMemoryV2.self)
    ]
  }
}

private enum FailingMemoryMigration: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { FixtureMemoryMigration.schemas }
  static var stages: [MigrationStage] {
    [
      .custom(
        fromVersion: MemorySchemaV1.self, toVersion: FixtureMemoryV2.self,
        willMigrate: { _ in throw AgentError.memoryFailure("Deliberately failed test migration.") },
        didMigrate: nil)
    ]
  }
}
