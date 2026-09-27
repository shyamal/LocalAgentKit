import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitTools

@Suite struct DocumentSearchToolTests {
  private func tool(_ store: MockVectorStore, limit: Int = 5) -> DocumentSearchTool {
    DocumentSearchTool(embeddingProvider: MockEmbeddingProvider(), vectorStore: store, limit: limit)
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
}
