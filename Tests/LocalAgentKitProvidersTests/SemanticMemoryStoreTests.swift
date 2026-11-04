import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitProviders

@Suite struct SemanticMemoryStoreTests {
  @Test(arguments: [false, true])
  func sharedContractFiltersBeforeLimitingAndUpdatesByIdentity(useMock: Bool) async throws {
    let store: any MemoryStore =
      useMock
      ? MockMemoryStore() : try SwiftDataMemoryStore(storage: .inMemory)
    let old = Date(timeIntervalSince1970: 100)
    let fact = SemanticMemory(kind: .fact, content: "Work in Paris", createdAt: old)
    var preference = SemanticMemory(
      kind: .preference, content: "Prefer concise answers", createdAt: old,
      metadata: ["source": "settings"])
    // Unrelated rows precede the target in both insertion-order and newest-first stores.
    for index in 0..<8 {
      try await store.save(Memory(content: "Unrelated \(index)"))
    }
    try await store.save(fact)
    try await store.save(preference)
    #expect(try await store.searchSemantic(text: "", kind: .preference, limit: 1) == [preference])
    #expect(try await store.searchSemantic(text: "Paris", kind: .fact) == [fact])
    #expect(try await store.searchSemantic(text: "", limit: 10).count == 2)
    #expect(try await store.searchSemantic(text: "", limit: 0).isEmpty)
    #expect(try await store.searchSemantic(text: "", limit: -1).isEmpty)
    preference.content = "Prefer detailed answers"
    try await store.save(preference)
    #expect(try await store.searchSemantic(text: "concise").isEmpty)
    #expect(try await store.searchSemantic(text: "", kind: .preference) == [preference])
    try await store.delete(id: preference.id)
    #expect(try await store.searchSemantic(text: "", kind: .preference).isEmpty)
    #expect(try await store.searchSemantic(text: "", kind: .fact) == [fact])
    #expect(try await store.search(MemoryQuery(text: "Unrelated", limit: 20)).count == 8)
  }

  @Test(arguments: [false, true])
  func exactMetadataConstraintsAreCombinedBeforeLimit(useMock: Bool) async throws {
    let store: any MemoryStore =
      useMock
      ? MockMemoryStore() : try SwiftDataMemoryStore(storage: .inMemory)
    let date = Date(timeIntervalSince1970: 100)
    try await store.save(Memory(content: "Match", metadata: ["a": "one", "b": "wrong"]))
    let target = Memory(content: "Match", createdAt: date, metadata: ["a": "one", "b": "two"])
    try await store.save(target)
    #expect(
      try await store.search(
        MemoryQuery(text: "Match", limit: 1, metadata: ["a": "one", "b": "two"]))
        == [target])
    #expect(try await store.search(MemoryQuery(text: "", metadata: ["a": "ONE"])).isEmpty)
    #expect(try await store.search(MemoryQuery(text: "", metadata: ["missing": ""])).isEmpty)
    #expect(try await store.search(MemoryQuery(text: "", limit: -1)).isEmpty)
  }

  @Test func semanticFactsAndPreferencesSurviveReopeningAndDeletion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("semantic.store")
    let fact = SemanticMemory(
      kind: .fact, content: "Lives in Paris", metadata: ["source": "profile"])
    let preference = SemanticMemory(kind: .preference, content: "Use metric units")
    try await seedFile(url, values: [fact, preference])
    let store = try SwiftDataMemoryStore(storage: .file(url))
    #expect(try await store.searchSemantic(text: "", kind: .fact) == [fact])
    #expect(try await store.searchSemantic(text: "", kind: .preference) == [preference])
    try await store.delete(id: fact.id)
    let reopened = try SwiftDataMemoryStore(storage: .file(url))
    #expect(try await reopened.searchSemantic(text: "", kind: .fact).isEmpty)
    #expect(try await reopened.searchSemantic(text: "", kind: .preference) == [preference])
  }

  @Test(arguments: [false, true])
  func unsupportedSemanticVersionFailsInsteadOfDisappearing(useMock: Bool) async throws {
    let store: any MemoryStore =
      useMock
      ? MockMemoryStore() : try SwiftDataMemoryStore(storage: .inMemory)
    var record = try SemanticMemory(kind: .fact, content: "Future format").memory()
    record.metadata["localagentkit.semantic.version"] = "99"
    try await store.save(record)
    await #expect(
      throws: AgentError.memoryFailure("Invalid or unsupported semantic memory record.")
    ) {
      try await store.searchSemantic(text: "")
    }
  }

  @Test func cancelledSemanticOperationsDoNotReachTheStore() async throws {
    let store = MockMemoryStore()
    let value = SemanticMemory(kind: .preference, content: "Use metric units")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await #expect(throws: AgentError.cancelled) { try await store.save(value) }
      await #expect(throws: AgentError.cancelled) { try await store.searchSemantic(text: "") }
    }
    await task.value
    #expect(await store.all.isEmpty)
  }

  @Test func invalidSemanticSaveLeavesExistingRecordIntact() async throws {
    let store = try SwiftDataMemoryStore(storage: .inMemory)
    var value = SemanticMemory(kind: .fact, content: "Keep this")
    try await store.save(value)
    value.content = " "
    await #expect(throws: AgentError.memoryFailure("Semantic memory content must not be blank.")) {
      try await store.save(value)
    }
    #expect(try await store.searchSemantic(text: "").first?.content == "Keep this")
  }

  private func seedFile(_ url: URL, values: [SemanticMemory]) async throws {
    let store = try SwiftDataMemoryStore(storage: .file(url))
    for value in values { try await store.save(value) }
  }
}
