/// Controls one persistent-memory search per run. Results share the context budgeter's
/// retrieval allocation with RAG passages; retrieval never bypasses context fitting.
public struct MemoryRetrievalConfiguration: Sendable, Hashable {
  /// How the query text is formed; matching and ordering still belong to the store.
  public enum Query: Sendable, Hashable {
    /// Search using the entire current goal, without rewriting or keyword extraction.
    case goal
    /// Search with empty text, allowing the store to return its first matching records.
    /// SwiftData returns newest recordings first; the mock uses insertion order.
    case recent
  }

  /// Goal text by default; use recent for general facts/preferences regardless of goal wording.
  public var query: Query
  /// Maximum retrieved records. Zero disables searches; negative values are invalid.
  public var limit: Int
  /// Exact metadata constraints, passed to the store before its result limit.
  public var metadata: [String: String]

  /// Creates a retrieval policy. Default searches match the entire goal and return at most five.
  public init(query: Query = .goal, limit: Int = 5, metadata: [String: String] = [:]) {
    self.query = query
    self.limit = limit
    self.metadata = metadata
  }

  /// The configuration issue that prevents a runtime from using this policy, if any.
  public var issue: ConfigurationIssue? {
    limit < 0 ? .invalidLimit("memory retrieval limit must not be negative") : nil
  }
}
