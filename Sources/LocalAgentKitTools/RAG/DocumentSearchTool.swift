import LocalAgentKitCore

/// Search inside the contents of the user's indexed documents (FR-008, FR-013). `.readOnly`.
public struct DocumentSearchTool: AgentTool {
  /// Registered action name `search_documents`.
  public let name = "search_documents"
  /// Prompt-facing guidance for finding passages in indexed documents.
  public let description =
    "Search inside the contents of the user's indexed documents and return the most relevant "
    + "passages. Use to answer questions about what a document says."
  /// Requires nonempty query text, also checked by execution.
  public let schema = ToolSchema(
    parameters: [
      "query": ToolParameter(.string, description: "What to look for in the document contents.")
    ], required: ["query"])
  /// Read-only retrieval of passages already indexed by the host.
  public let permission = ToolPermission.readOnly
  /// True when the injected embedding and vector-store components safely support concurrent calls.
  public let isParallelSafe = true
  /// Advertises cancellation support; retrieval propagates cancellation rather than returning no hits.
  public let isCancellable = true
  private let pipeline: RetrievalPipeline
  private let limit: Int
  private let retrieval: RetrievalConfiguration?

  /// Creates a search tool sharing ingestion's embedding space and vector store.
  /// The result limit is clamped to at least one.
  public init(
    embeddingProvider: any EmbeddingProvider, vectorStore: any VectorStore, limit: Int = 5
  ) {
    self.pipeline = RetrievalPipeline(
      embeddingProvider: embeddingProvider, vectorStore: vectorStore)
    self.limit = max(1, limit)
    self.retrieval = nil
  }

  /// Creates an explicitly tuned search tool. Invalid settings fail before tool execution.
  /// No threshold is calibrated by this initializer; use settings measured for this embedding space/store.
  public init(
    embeddingProvider: any EmbeddingProvider, vectorStore: any VectorStore,
    retrieval: RetrievalConfiguration
  ) throws {
    if let issue = retrieval.issue { throw AgentError.invalidConfiguration(issue) }
    self.pipeline = RetrievalPipeline(
      embeddingProvider: embeddingProvider, vectorStore: vectorStore)
    self.limit = retrieval.resultLimit
    self.retrieval = retrieval
  }

  /// Retrieves passages for the query; ordinary retrieval failures degrade to an empty result.
  /// Invalid arguments and cancellation remain errors instead of being hidden as no results.
  public func execute(arguments: ToolArguments) async throws -> ToolResult {
    guard let query = arguments.string("query"), !query.isEmpty else {
      throw AgentError.invalidArguments(tool: name, violations: [.missingRequired(path: "query")])
    }
    let passages: [String]
    do {
      if let retrieval {
        passages = try await pipeline.retrieve(for: query, configuration: retrieval)
      } else {
        passages = try await pipeline.retrieve(for: query, limit: limit)
      }
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
