import LocalAgentKitCore
import Testing

@testable import LocalAgentKitProviders

@Suite struct InMemoryVectorStoreTests {
  @Test func insertAndSearchRanksBySimilarity() async throws {
    let store = InMemoryVectorStore()
    try await store.insert([
      EmbeddedDocument(text: "matches well", vector: [1, 0, 0]),
      EmbeddedDocument(text: "orthogonal", vector: [0, 1, 0]),
      EmbeddedDocument(text: "close match", vector: [0.9, 0.1, 0]),
    ])
    let results = try await store.search(vector: [1, 0, 0], limit: 2)
    #expect(results.count == 2)
    #expect(results[0].document.text == "matches well")
    #expect(results[1].document.text == "close match")
    #expect(results[0].score >= results[1].score)
    #expect(await store.count == 3)
  }

  @Test func limitIsRespected() async throws {
    let store = InMemoryVectorStore()
    try await store.insert((0..<10).map { EmbeddedDocument(text: "d\($0)", vector: [1, 0]) })
    #expect(try await store.search(vector: [1, 0], limit: 3).count == 3)
  }

  @Test func zeroLimitReturnsNothing() async throws {
    let store = InMemoryVectorStore()
    try await store.insert([EmbeddedDocument(text: "d", vector: [1, 0])])
    #expect(try await store.search(vector: [1, 0], limit: 0).isEmpty)
  }

  @Test func emptyStoreReturnsNothing() async throws {
    let store = InMemoryVectorStore()
    #expect(try await store.search(vector: [1, 0], limit: 5).isEmpty)
  }

  @Test func mismatchedDimensionsAreSkippedNotCrashed() async throws {
    let store = InMemoryVectorStore()
    try await store.insert([EmbeddedDocument(text: "d", vector: [1, 0, 0])])
    #expect(try await store.search(vector: [1, 0], limit: 5).isEmpty)
  }

  @Test func aZeroVectorNeverMatches() async throws {
    let store = InMemoryVectorStore()
    try await store.insert([EmbeddedDocument(text: "d", vector: [0, 0])])
    #expect(try await store.search(vector: [1, 0], limit: 5).isEmpty)
  }

  @Test func removeDeletesByID() async throws {
    let store = InMemoryVectorStore()
    let keep = EmbeddedDocument(text: "keep", vector: [1, 0])
    let drop = EmbeddedDocument(text: "drop", vector: [0, 1])
    try await store.insert([keep, drop])
    await store.remove(ids: [drop.id])
    #expect(await store.count == 1)
    let results = try await store.search(vector: [0, 1], limit: 5)
    #expect(!results.contains { $0.document.text == "drop" })
  }
}
