import Foundation

/// A document before chunking (FR-013). `DocumentLoader` produces one from a file; an app can
/// also build one directly from text already in memory.
public struct Document: Sendable, Hashable, Identifiable {
  /// Identity carried into each chunk's document reference.
  public var id: UUID
  /// Display title copied into chunk metadata by the chunker.
  public var title: String
  /// Full extracted document text before chunking.
  public var text: String

  /// Creates a text document with a generated identity when omitted.
  public init(id: UUID = UUID(), title: String, text: String) {
    self.id = id
    self.title = title
    self.text = text
  }
}

/// One piece of a chunked document, before embedding.
public struct DocumentChunk: Sendable, Hashable, Identifiable {
  /// Unique identity for this chunk, reused when embedding it.
  public var id: UUID
  /// Identity of the original document.
  public var documentID: UUID
  /// Text of this individual passage.
  public var text: String
  /// App-defined attributes such as document title and chunk index.
  public var metadata: [String: String]

  /// Creates a passage linked to its source document and optional metadata.
  public init(
    id: UUID = UUID(), documentID: UUID, text: String, metadata: [String: String] = [:]
  ) {
    self.id = id
    self.documentID = documentID
    self.text = text
    self.metadata = metadata
  }
}
