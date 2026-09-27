import Foundation

/// A document before chunking (FR-013). `DocumentLoader` produces one from a file; an app can
/// also build one directly from text already in memory.
public struct Document: Sendable, Hashable, Identifiable {
  public var id: UUID
  public var title: String
  public var text: String

  public init(id: UUID = UUID(), title: String, text: String) {
    self.id = id
    self.title = title
    self.text = text
  }
}

/// One piece of a chunked document, before embedding.
public struct DocumentChunk: Sendable, Hashable, Identifiable {
  public var id: UUID
  public var documentID: UUID
  public var text: String
  public var metadata: [String: String]

  public init(
    id: UUID = UUID(), documentID: UUID, text: String, metadata: [String: String] = [:]
  ) {
    self.id = id
    self.documentID = documentID
    self.text = text
    self.metadata = metadata
  }
}
