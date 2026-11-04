import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import SwiftData
import Testing

@testable import LocalAgentKitProviders

@Suite struct SwiftDataMemoryStoreTests {
  @Test(arguments: [false, true])
  func memoryContractRoundTripsReplacesAndDeletes(useMock: Bool) async throws {
    let store: any MemoryStore
    if useMock {
      store = MockMemoryStore()
    } else {
      store = try SwiftDataMemoryStore(storage: .inMemory)
    }
    let original = Memory(content: "Budget review", metadata: ["category": "semantic"])
    try await store.save(original)
    #expect(try await store.search(MemoryQuery(text: "budget")) == [original])
    var updated = original
    updated.content = "Updated budget review"
    updated.metadata = ["category": "episodic"]
    updated.createdAt = original.createdAt.addingTimeInterval(60)
    try await store.save(updated)
    #expect(try await store.search(MemoryQuery(text: "budget")) == [updated])
    try await store.delete(id: original.id)
    try await store.delete(id: UUID())
    #expect(try await store.search(MemoryQuery(text: "")) == [])
  }

  @Test func localizedSearchLimitsAndStableOrdering() async throws {
    let store = try SwiftDataMemoryStore(storage: .inMemory)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let low = Memory(
      id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
      content: "CAFÉ planning", createdAt: date)
    let high = Memory(
      id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
      content: "Café review", createdAt: date)
    let newest = Memory(content: "cafe next steps", createdAt: date.addingTimeInterval(60))
    let unrelated = Memory(content: "Unrelated", metadata: ["topic": "cafe"])
    for memory in [high, low, newest, unrelated] { try await store.save(memory) }
    #expect(try await store.search(MemoryQuery(text: "cafe", limit: 9)) == [newest, low, high])
    #expect(try await store.search(MemoryQuery(text: "cafe", limit: 2)) == [newest, low])
    #expect(try await store.search(MemoryQuery(text: "", limit: 0)).isEmpty)
    #expect(try await store.search(MemoryQuery(text: "", limit: -1)).isEmpty)
  }

  @Test func diskStorePersistsUpdatesAndDeletionAcrossReopens() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("nested/memory.store")
    let original = Memory(content: "Original", metadata: ["key": "value"])
    try await writeAndReplace(original, at: url)
    let reopened = try SwiftDataMemoryStore(storage: .file(url))
    var expected = original
    expected.content = "Replaced"
    #expect(try await reopened.search(MemoryQuery(text: "")) == [expected])
    try await reopened.delete(id: original.id)
    let final = try SwiftDataMemoryStore(storage: .file(url))
    #expect(try await final.search(MemoryQuery(text: "")).isEmpty)
  }

  @Test(arguments: ["save", "search", "delete"])
  func alreadyCancelledOperationsDoNotMutate(operation: String) async throws {
    let store = try SwiftDataMemoryStore(storage: .inMemory)
    let memory = Memory(content: "Keep me")
    try await store.save(memory)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        switch operation {
        case "save": try await store.save(Memory(content: "Must not persist"))
        case "delete": try await store.delete(id: memory.id)
        default: _ = try await store.search(MemoryQuery(text: ""))
        }
        Issue.record("Expected cancellation")
      } catch let error as AgentError {
        #expect(error == .cancelled)
      }
    }
    try await task.value
    #expect(try await store.search(MemoryQuery(text: "")) == [memory])
  }

  @MainActor @Test func corruptStoredMetadataSurfacesThroughSearch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("memory.store")
    do {
      let schema = Schema(versionedSchema: MemorySchemaV1.self)
      let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let context = ModelContext(container)
      context.autosaveEnabled = false
      let record = try MemorySchemaV1.StoredMemory(memory: Memory(content: "Corrupt metadata"))
      record.metadataJSON = Data("[]".utf8)
      context.insert(record)
      try context.save()
    }
    let store = try SwiftDataMemoryStore(storage: .file(url))
    await #expect(throws: AgentError.memoryFailure("Could not decode stored memory metadata.")) {
      try await store.search(MemoryQuery(text: "Corrupt"))
    }
  }

  @Test func nonFileURLsAreTypedFailures() throws {
    let url = try #require(URL(string: "https://example.invalid/memory.store"))
    #expect(throws: AgentError.memoryFailure("Storage URL must be a file URL.")) {
      try SwiftDataMemoryStore(storage: .file(url))
    }
  }

  @Test func initializationFilesystemFailureIsTyped() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("not-a-directory")
    try Data().write(to: file)
    do {
      _ = try SwiftDataMemoryStore(storage: .file(file.appendingPathComponent("memory.store")))
      Issue.record("Expected filesystem initialization failure")
    } catch let error as AgentError {
      guard case .memoryFailure = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
  }

  @MainActor @Test func mainActorConstructionCanBeUsedFromAnotherTask() async throws {
    let store = try SwiftDataMemoryStore(storage: .inMemory)
    let memory = Memory(content: "Created on the UI actor")
    try await Task.detached { try await store.save(memory) }.value
    #expect(try await store.search(MemoryQuery(text: "UI actor")) == [memory])
  }

  @Test func concurrentSavesAreSerialized() async throws {
    let store = try SwiftDataMemoryStore(storage: .inMemory)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<20 {
        group.addTask { try await store.save(Memory(content: "Memory \(index)")) }
      }
      try await group.waitForAll()
    }
    #expect(try await store.search(MemoryQuery(text: "Memory", limit: 30)).count == 20)
  }

  private func writeAndReplace(_ memory: Memory, at url: URL) async throws {
    let store = try SwiftDataMemoryStore(storage: .file(url))
    try await store.save(memory)
    var updated = memory
    updated.content = "Replaced"
    try await store.save(updated)
  }
}
