import LocalAgentKitCore

/// Search inside the contents of the user's indexed documents (FR-008, FR-013). `.readOnly`.
public struct DocumentSearchTool: AgentTool {
  public let name = "search_documents"
  public let description =
    "Search inside the contents of the user's indexed documents and return the most relevant "
    + "passages. Use to answer questions about what a document says."
  public let schema = ToolSchema(
    parameters: [
      "query": ToolParameter(.string, description: "What to look for in the document contents.")
    ], required: ["query"])
  public let permission = ToolPermission.readOnly
  public let isParallelSafe = true
  public let isCancellable = true
  private let pipeline: RetrievalPipeline
  private let limit: Int

  public init(
    embeddingProvider: any EmbeddingProvider, vectorStore: any VectorStore, limit: Int = 5
  ) {
    self.pipeline = RetrievalPipeline(
      embeddingProvider: embeddingProvider, vectorStore: vectorStore)
    self.limit = max(1, limit)
  }

  public func execute(arguments: ToolArguments) async throws -> ToolResult {
    guard let query = arguments.string("query"), !query.isEmpty else {
      throw AgentError.invalidArguments(tool: name, violations: [.missingRequired(path: "query")])
    }
    let passages: [String]
    do {
      passages = try await pipeline.retrieve(for: query, limit: limit)
    } catch AgentError.cancelled {
      throw AgentError.cancelled
    } catch is CancellationError {
      throw AgentError.cancelled
    } catch {
      // The embedding provider or vector store failed — an unavailable on-device model asset,
      // for instance (`NLEmbeddingProvider` throws `.retrievalFailure` when the sentence-
      // embedding asset isn't present). This is a read-only search: reporting "nothing found"
      // lets the conversation continue instead of ending the whole run over it.
      return ToolResult(callID: "", toolName: name, text: "No results found.", isEmpty: true)
    }
    guard !passages.isEmpty else {
      return ToolResult(callID: "", toolName: name, text: "No results found.", isEmpty: true)
    }
    let text = passages.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(
      separator: "\n\n")
    return ToolResult(
      callID: "", toolName: name, text: text, structured: .array(passages.map(JSONValue.string)))
  }
}
