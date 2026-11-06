import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitTools

/// Stands in for `NLEmbeddingProvider` when its on-device sentence-embedding asset isn't
/// available — the failure this tool must degrade gracefully from.
private struct FailingEmbeddingProvider: EmbeddingProvider {
  let requiresNetwork = false
  func embed(text: String) async throws -> [Float] {
    throw AgentError.retrievalFailure("no sentence embedding model for this language")
  }
}

@Suite struct DocumentSearchToolTests {
  private func tool(_ store: MockVectorStore, limit: Int = 5) -> DocumentSearchTool {
    DocumentSearchTool(embeddingProvider: MockEmbeddingProvider(), vectorStore: store, limit: limit)
  }

  @Test func explicitSelectionDeduplicatesAndCanReturnNoResults() async throws {
    let store = MockVectorStore()
    let embedding = MockEmbeddingProvider()
    let vector = try await embedding.embed(text: "budget")
    try await store.insert([
      EmbeddedDocument(text: "budget", vector: vector),
      EmbeddedDocument(text: "budget", vector: vector),
    ])
    let selected = try DocumentSearchTool(
      embeddingProvider: embedding, vectorStore: store,
      retrieval: .init(resultLimit: 2, candidateLimit: 4))
    let result = try await selected.execute(arguments: ToolArguments(["query": "budget"]))
    #expect(result.structured == .array([.string("budget")]))
    #expect(selected.permission == .readOnly)
    let rejected = try DocumentSearchTool(
      embeddingProvider: embedding, vectorStore: store,
      retrieval: .init(minimumScore: 2))
    #expect(try await rejected.execute(arguments: ToolArguments(["query": "budget"])).isEmpty)
  }

  @Test func invalidSelectionIsRejectedBeforeToolExecution() {
    #expect(throws: AgentError.self) {
      try DocumentSearchTool(
        embeddingProvider: MockEmbeddingProvider(), vectorStore: MockVectorStore(),
        retrieval: .init(candidateLimit: 0))
    }
  }

  @Test func propertiesMatchFR008() {
    let tool = tool(MockVectorStore())
    #expect(tool.name == "search_documents")
    #expect(tool.permission == .readOnly)
    #expect(tool.schema.required == ["query"])
  }

  @Test func missingQueryIsInvalidArguments() async {
    let tool = tool(MockVectorStore())
    await #expect(
      throws: AgentError.invalidArguments(
        tool: "search_documents", violations: [.missingRequired(path: "query")])
    ) {
      try await tool.execute(arguments: ToolArguments())
    }
  }

  @Test func noResultsIsAnEmptyResultWithClearText() async throws {
    let tool = tool(MockVectorStore())
    let result = try await tool.execute(arguments: ToolArguments(["query": "budget"]))
    #expect(result.isEmpty)
    #expect(result.text == "No results found.")
  }

  @Test func resultsAreNumberedAndStructured() async throws {
    let store = MockVectorStore()
    let embedder = MockEmbeddingProvider()
    for text in ["budget meeting notes", "unrelated zebra facts"] {
      try await store.insert([
        EmbeddedDocument(text: text, vector: try await embedder.embed(text: text))
      ])
    }
    let result = try await tool(store).execute(arguments: ToolArguments(["query": "budget"]))
    #expect(!result.isEmpty)
    #expect(result.text.contains("[1]"))
    #expect(result.text.contains("budget meeting notes"))
    #expect(result.structured != nil)
  }

  @Test func limitIsPassedThrough() async throws {
    let store = MockVectorStore()
    let embedder = MockEmbeddingProvider()
    for index in 0..<10 {
      let text = "note about budgets number \(index)"
      try await store.insert([
        EmbeddedDocument(text: text, vector: try await embedder.embed(text: text))
      ])
    }
    let result = try await tool(store, limit: 2).execute(
      arguments: ToolArguments(["query": "budget"]))
    #expect(result.text.contains("[1]"))
    #expect(result.text.contains("[2]"))
    #expect(!result.text.contains("[3]"))
  }

  /// A missing on-device model asset — a real, observed condition (`NLEmbeddingProvider` throws
  /// `.retrievalFailure`) — must not end the whole run: `search_documents` is read-only, so it
  /// reports no results rather than failing the conversation.
  @Test func anEmbeddingFailureIsReportedAsNoResultsNotThrown() async throws {
    let tool = DocumentSearchTool(
      embeddingProvider: FailingEmbeddingProvider(), vectorStore: MockVectorStore())
    let result = try await tool.execute(arguments: ToolArguments(["query": "budget"]))
    #expect(result.isEmpty)
    #expect(result.text == "No results found.")
  }
}
