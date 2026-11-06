import Foundation
import LocalAgentKitCore

/// A local, in-memory vector store using brute-force cosine similarity (FR-015) — fine at the
/// single-user, single-workspace scale this is built for, with no network dependency. Not
/// durable: content is re-ingested each launch. Use `FileVectorStore` for small-corpus snapshots
/// that survive reopening, with explicit embedding-space and dimension configuration.
public actor InMemoryVectorStore: VectorStore {
  private var documents: [EmbeddedDocument] = []

  /// Creates an empty non-durable passage store.
  public init() {}

  /// Number of stored passages, including any duplicate IDs inserted by the caller.
  public var count: Int { documents.count }

  /// Appends passages without deduplication; checks cancellation before insertion.
  public func insert(_ documents: [EmbeddedDocument]) async throws {
    try Task.checkCancellation()
    self.documents += documents
  }

  /// Returns up to `limit` passages by descending cosine similarity.
  /// Non-positive limits return no hits; incompatible dimensions and zero vectors are skipped.
  public func search(vector: [Float], limit: Int) async throws -> [SearchResult] {
    try Task.checkCancellation()
    guard limit > 0 else { return [] }
    let scored = documents.compactMap { document -> SearchResult? in
      Self.cosineSimilarity(vector, document.vector).map {
        SearchResult(document: document, score: $0)
      }
    }
    return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
  }

  /// Removes every embedded document with an id in `ids` — for re-ingesting an updated document
  /// without duplicating its old chunks.
  public func remove(ids: Set<UUID>) async {
    documents.removeAll { ids.contains($0.id) }
  }

  private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float? {
    guard a.count == b.count, !a.isEmpty else { return nil }
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    for index in a.indices {
      dot += a[index] * b[index]
      normA += a[index] * a[index]
      normB += b[index] * b[index]
    }
    let denominator = normA.squareRoot() * normB.squareRoot()
    guard denominator > 0 else { return nil }
    return dot / denominator
  }
}
