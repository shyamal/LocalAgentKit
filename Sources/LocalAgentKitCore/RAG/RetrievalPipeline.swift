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
  /// This direct API remains a single insert; Runtime's `IngestionJob` provides explicit
  /// lazy sources, bounded embedding batches, progress and cooperative background cancellation.
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

  /// Selects scored passages from one bounded candidate window. Configuration is checked before
  /// embedding. Nonfinite scores and blank text are discarded, then hits are ranked descending
  /// (store order breaks ties), filtered inclusively and deduplicated before applying resultLimit.
  /// No refill, semantic deduplication, calibrated cutoff or proof of answer presence is implied.
  /// - Throws: `.invalidConfiguration`, typed cancellation or `.retrievalFailure` for unknown provider errors.
  public func search(for query: String, configuration: RetrievalConfiguration) async throws
    -> [SearchResult]
  {
    do {
      try checkCancellation()
      if let issue = configuration.issue { throw AgentError.invalidConfiguration(issue) }
      let vector = try await embeddingProvider.embed(text: query)
      try checkCancellation()
      let candidates = try await vectorStore.search(
        vector: vector, limit: configuration.candidateLimit)
      try checkCancellation()
      let ranked = candidates.prefix(configuration.candidateLimit).enumerated()
        .filter { hit in
          hit.element.score.isFinite
            && !hit.element.document.text.split(whereSeparator: \.isWhitespace).isEmpty
            && (configuration.minimumScore.map { hit.element.score >= $0 } ?? true)
        }
        .sorted { left, right in
          left.element.score == right.element.score
            ? left.offset < right.offset : left.element.score > right.element.score
        }
      var seen: Set<String> = []
      var selected: [SearchResult] = []
      for hit in ranked {
        try checkCancellation()
        let document = hit.element.document
        let key: String?
        switch configuration.deduplication {
        case .none: key = nil
        case .passageID: key = document.id.uuidString
        case .exactText: key = document.text
        case .normalizedWhitespace:
          key = document.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        if let key, !seen.insert(key).inserted { continue }
        selected.append(hit.element)
        if selected.count == configuration.resultLimit { break }
      }
      try checkCancellation()
      return selected
    } catch let error as AgentError { throw error } catch is CancellationError {
      throw AgentError.cancelled
    } catch { throw AgentError.retrievalFailure("Scored retrieval failed") }

  }

  /// Returns selected texts through the same scored selection path, ready for context fitting.
  public func retrieve(for query: String, configuration: RetrievalConfiguration) async throws
    -> [String]
  {
    try await search(for: query, configuration: configuration).map(\.document.text)
  }

  private func checkCancellation() throws {
    if Task.isCancelled { throw AgentError.cancelled }
  }

}
