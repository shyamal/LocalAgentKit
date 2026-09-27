import Foundation
import LocalAgentKitCore

/// A memory store backed by an array. `search` matches case-insensitive substrings.
public actor MockMemoryStore: MemoryStore {
  private var memories: [Memory]

  public init(_ memories: [Memory] = []) {
    self.memories = memories
  }

  public var all: [Memory] { memories }

  public func save(_ memory: Memory) async throws {
    memories.removeAll { $0.id == memory.id }
    memories.append(memory)
  }

  public func search(_ query: MemoryQuery) async throws -> [Memory] {
    let needle = query.text.lowercased()
    return Array(
      memories.filter { needle.isEmpty || $0.content.lowercased().contains(needle) }
        .prefix(query.limit))
  }

  public func delete(id: UUID) async throws {
    memories.removeAll { $0.id == id }
  }
}

/// Deterministic embeddings with no model: a bag-of-letters vector, so texts that share letters
/// are closer. Good enough to test plumbing; not a retrieval-quality signal (that is M3-04).
public struct MockEmbeddingProvider: EmbeddingProvider {
  public let requiresNetwork: Bool

  public init(requiresNetwork: Bool = false) {
    self.requiresNetwork = requiresNetwork
  }

  public func embed(text: String) async throws -> [Float] {
    try Task.checkCancellation()
    var vector = [Float](repeating: 0, count: 26)
    for scalar in text.lowercased().unicodeScalars where scalar.value >= 97 && scalar.value <= 122 {
      vector[Int(scalar.value) - 97] += 1
    }
    return vector
  }
}

/// A brute-force cosine-similarity store held in memory. Records inserts for assertions.
public actor MockVectorStore: VectorStore {
  private var documents: [EmbeddedDocument] = []

  public init() {}

  public var stored: [EmbeddedDocument] { documents }

  public func insert(_ documents: [EmbeddedDocument]) async throws {
    self.documents += documents
  }

  public func search(vector: [Float], limit: Int) async throws -> [SearchResult] {
    let scored = documents.map { SearchResult(document: $0, score: Self.cosine(vector, $0.vector)) }
    return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
  }

  private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return 0 }
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    for index in a.indices {
      dot += a[index] * b[index]
      normA += a[index] * a[index]
      normB += b[index] * b[index]
    }
    let denominator = normA.squareRoot() * normB.squareRoot()
    return denominator > 0 ? dot / denominator : 0
  }
}
