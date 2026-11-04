import Foundation
import LocalAgentKitCore

/// A memory store backed by an array. `search` matches case-insensitive substrings.
public actor MockMemoryStore: MemoryStore {
  private var memories: [Memory]

  /// Creates a non-durable memory store seeded with the supplied entries.
  public init(_ memories: [Memory] = []) {
    self.memories = memories
  }

  /// All currently stored entries in insertion order.
  public var all: [Memory] { memories }

  /// Replaces any memory with the same ID, then appends the supplied entry.
  public func save(_ memory: Memory) async throws {
    memories.removeAll { $0.id == memory.id }
    memories.append(memory)
  }

  /// Returns case-insensitive content matches satisfying exact metadata constraints, in insertion
  /// order. Constraints apply before the limit; non-positive limits return no results.
  public func search(_ query: MemoryQuery) async throws -> [Memory] {
    if Task.isCancelled { throw AgentError.cancelled }
    guard query.limit > 0 else { return [] }
    let needle = query.text.lowercased()
    return Array(
      memories.filter { memory in
        (needle.isEmpty || memory.content.lowercased().contains(needle))
          && query.metadata.allSatisfy { memory.metadata[$0.key] == $0.value }
      }
      .prefix(query.limit))
  }

  /// Removes all entries with the given identity; absent IDs do nothing.
  public func delete(id: UUID) async throws {
    memories.removeAll { $0.id == id }
  }
}

/// Deterministic embeddings with no model: a bag-of-letters vector, so texts that share letters
/// are closer. Good enough to test plumbing; not a retrieval-quality signal (that is M3-04).
public struct MockEmbeddingProvider: EmbeddingProvider {
  /// Configurable declaration for testing offline-policy construction checks.
  public let requiresNetwork: Bool

  /// Creates a deterministic letter-count embedding provider with an optional network declaration.
  public init(requiresNetwork: Bool = false) {
    self.requiresNetwork = requiresNetwork
  }

  /// Counts ASCII letters into a 26-component vector after a cancellation check.
  /// This is deterministic plumbing data, not a semantic embedding-quality benchmark.
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

  /// Creates an empty in-memory vector-store test double.
  public init() {}

  /// Inserted documents in insertion order, including duplicates.
  public var stored: [EmbeddedDocument] { documents }

  /// Appends documents without deduplication or durable storage.
  public func insert(_ documents: [EmbeddedDocument]) async throws {
    self.documents += documents
  }

  /// Returns documents by descending cosine similarity up to a non-negative limit.
  /// Dimension mismatches and zero norms receive score zero in this test double.
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
