/// Explicit candidate selection settings (M3-07). These are engineering controls, not a
/// calibrated answerability detector. Defaults apply only when this value is explicitly used.
public struct RetrievalConfiguration: Sendable, Hashable {
  /// Which repeated passages to suppress after ranking and score filtering.
  public enum Deduplication: Sendable, Hashable {
    /// Preserve duplicates.
    case none
    /// Keep the highest-ranked occurrence of each passage ID.
    case passageID
    /// Keep the highest-ranked occurrence of each exact text string, across IDs/sources.
    case exactText
    /// Collapse runs of Unicode whitespace before comparing text; preserve case and punctuation.
    case normalizedWhitespace
  }
  /// Maximum returned passages, after filtering/deduplication.
  public var resultLimit: Int
  /// Maximum candidates requested/considered, before filtering/deduplication. No refill occurs.
  public var candidateLimit: Int
  /// Inclusive lower score bound in the store's own units; nil disables it. No calibrated default.
  public var minimumScore: Float?
  /// Duplicate policy; selection retains the original text and metadata of the first ranked hit.
  public var deduplication: Deduplication

  /// Creates explicit selection settings; validate `issue` before use.
  public init(
    resultLimit: Int = 5, candidateLimit: Int = 20, minimumScore: Float? = nil,
    deduplication: Deduplication = .exactText
  ) {
    self.resultLimit = resultLimit
    self.candidateLimit = candidateLimit
    self.minimumScore = minimumScore
    self.deduplication = deduplication
  }
  /// First invalid limit/threshold, or nil. Finite scores are allowed outside cosine's range
  /// because custom stores may use other similarity scales; thresholds do not transfer across stores.
  public var issue: ConfigurationIssue? {
    if resultLimit < 1 { return .invalidLimit("retrieval resultLimit must be positive") }
    if candidateLimit < resultLimit {
      return .invalidLimit("candidateLimit must be at least resultLimit")
    }
    if let minimumScore, !minimumScore.isFinite {
      return .invalidLimit("retrieval minimumScore must be finite")
    }
    return nil
  }
}
