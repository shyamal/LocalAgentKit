/// Composes an ``EmbeddingProvider`` and a ``VectorStore`` into the two operations RAG needs
/// (M1-RG-05): ingest a document, and retrieve chunks for a query. Its `retrieve` output is
/// exactly what `ContextInputs.retrievedChunks` expects — the link between retrieval and
/// `ContextBudgeter`'s prompt-injection path.
public struct RetrievalPipeline: Sendable {
  /// Provider shared by document and query embedding operations.
  public let embeddingProvider: any EmbeddingProvider
  /// Destination for ingested passages and source of search results.
  public let vectorStore: any VectorStore

  /// Connects embedding and vector storage components using the same embedding space.
  public init(embeddingProvider: any EmbeddingProvider, vectorStore: any VectorStore) {
    self.embeddingProvider = embeddingProvider
    self.vectorStore = vectorStore
  }

  /// Chunks `document`, embeds each chunk, and inserts them into the vector store.
  public func ingest(_ document: Document, chunker: Chunker = Chunker()) async throws {
    let chunks = chunker.chunk(document)
    guard !chunks.isEmpty else { return }
    var embedded: [EmbeddedDocument] = []
    embedded.reserveCapacity(chunks.count)
    for chunk in chunks {
      let vector = try await embeddingProvider.embed(text: chunk.text)
      embedded.append(
        EmbeddedDocument(id: chunk.id, text: chunk.text, vector: vector, metadata: chunk.metadata))
    }
    try await vectorStore.insert(embedded)
  }

  /// Embeds `query` and returns the most relevant chunk texts, most relevant first.
  public func retrieve(for query: String, limit: Int = 5) async throws -> [String] {
    guard limit > 0 else { return [] }
    let vector = try await embeddingProvider.embed(text: query)
    return try await vectorStore.search(vector: vector, limit: limit).map(\.document.text)
  }
}
