import Foundation

/// Turns text into vectors (FR-014). Replaceable by design.
public protocol EmbeddingProvider: Sendable {
  /// True for a cloud embedding service; rejected under `NetworkPolicy.never` (FR-023).
  var requiresNetwork: Bool { get }

  /// Embeds text into a vector in this provider's vector space.
  /// Use the same embedding space for indexed documents and queries; report failures as retrieval errors.
  func embed(text: String) async throws -> [Float]
}

extension EmbeddingProvider {
  /// Default declaration for a local embedding provider.
  public var requiresNetwork: Bool { false }
}

/// A searchable passage with its embedding and app-defined metadata.
public struct EmbeddedDocument: Sendable, Hashable, Identifiable {
  /// Identity used to correlate or remove an indexed passage.
  public var id: UUID
  /// Passage text returned to consumers after a similarity search.
  public var text: String
  /// Embedding components; query and indexed vectors must share a vector space.
  public var vector: [Float]
  /// Attributes retained alongside the passage.
  public var metadata: [String: String]

  /// Creates an indexed passage with an identity, text, vector and optional metadata.
  public init(
    id: UUID = UUID(), text: String, vector: [Float], metadata: [String: String] = [:]
  ) {
    self.id = id
    self.text = text
    self.vector = vector
    self.metadata = metadata
  }
}

/// An indexed passage paired with its similarity to a search vector.
public struct SearchResult: Sendable, Hashable {
  /// The matched passage and its stored embedding.
  public var document: EmbeddedDocument
  /// Similarity, higher is closer.
  public var score: Float

  /// Creates a search hit with an implementation-defined similarity score.
  public init(document: EmbeddedDocument, score: Float) {
    self.document = document
    self.score = score
  }
}

/// Stores and searches embedded documents (FR-015).
public protocol VectorStore: Sendable {
  /// Stores embedded passages; implementations define duplicate-ID and persistence behavior.
  func insert(_ documents: [EmbeddedDocument]) async throws
  /// Returns at most `limit` similar passages, highest similarity first.
  /// Use a non-negative limit and vectors from the indexing provider's embedding space.
  func search(vector: [Float], limit: Int) async throws -> [SearchResult]
}
