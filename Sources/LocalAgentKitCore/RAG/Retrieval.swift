import Foundation

/// Turns text into vectors (FR-014). Replaceable by design.
public protocol EmbeddingProvider: Sendable {
  /// True for a cloud embedding service; rejected under `NetworkPolicy.never` (FR-023).
  var requiresNetwork: Bool { get }

  func embed(text: String) async throws -> [Float]
}

extension EmbeddingProvider {
  public var requiresNetwork: Bool { false }
}

public struct EmbeddedDocument: Sendable, Hashable, Identifiable {
  public var id: UUID
  public var text: String
  public var vector: [Float]
  public var metadata: [String: String]

  public init(
    id: UUID = UUID(), text: String, vector: [Float], metadata: [String: String] = [:]
  ) {
    self.id = id
    self.text = text
    self.vector = vector
    self.metadata = metadata
  }
}

public struct SearchResult: Sendable, Hashable {
  public var document: EmbeddedDocument
  /// Similarity, higher is closer.
  public var score: Float

  public init(document: EmbeddedDocument, score: Float) {
    self.document = document
    self.score = score
  }
}

/// Stores and searches embedded documents (FR-015).
public protocol VectorStore: Sendable {
  func insert(_ documents: [EmbeddedDocument]) async throws
  func search(vector: [Float], limit: Int) async throws -> [SearchResult]
}
