import Foundation
import LocalAgentKitCore
import SwiftData
import Testing

@testable import LocalAgentKitProviders

@MainActor
@Suite struct MemorySchemaTests {
  @Test func inMemoryStorePreservesIdentityTextTimestampAndMetadata() throws {
    let original = Memory(
      content: "Budget review — 準備 📝\nSecond line",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      metadata: ["category": "semantic", "empty": "", "quoted": "a\"b\\c"])
    let schema = Schema(versionedSchema: MemorySchemaV1.self)
    let configuration = ModelConfiguration(
      schema: schema, isStoredInMemoryOnly: true, groupContainer: .none, cloudKitDatabase: .none)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    context.autosaveEnabled = false
    context.insert(try MemorySchemaV1.StoredMemory(memory: original))
    try context.save()
    let fetched = try #require(context.fetch(FetchDescriptor<MemorySchemaV1.StoredMemory>()).first)
    #expect(try fetched.memory() == original)
    #expect(schema.version == Schema.Version(1, 0, 0))
  }

  @Test func diskStoreReopensWithTheSameMemoryValues() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("memory.store")
    let original = Memory(content: "Remember the project sync", metadata: ["session": "demo"])
    try write(original, to: url)
    let schema = Schema(versionedSchema: MemorySchemaV1.self)
    let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
    let reopened = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(reopened)
    let records = try context.fetch(FetchDescriptor<MemorySchemaV1.StoredMemory>())
    #expect(records.count == 1)
    #expect(try records.first?.memory() == original)
  }

  @Test func corruptMetadataIsATypedFailureRatherThanAnEmptyDictionary() throws {
    let stored = try MemorySchemaV1.StoredMemory(memory: Memory(content: "test"))
    stored.metadataJSON = Data("not json".utf8)
    #expect(throws: AgentError.memoryFailure("Could not decode stored memory metadata.")) {
      try stored.memory()
    }
  }

  private func write(_ memory: Memory, to url: URL) throws {
    let schema = Schema(versionedSchema: MemorySchemaV1.self)
    let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    context.autosaveEnabled = false
    context.insert(try MemorySchemaV1.StoredMemory(memory: memory))
    try context.save()
  }
}
