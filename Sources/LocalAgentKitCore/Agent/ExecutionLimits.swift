/// Bounds on one agent run (FR-003).
///
/// Defaults are sized for the on-device model: a run is user-initiated and short, because the
/// iPhone reached `.serious` thermal state within five minutes of sustained work (findings §16).
public struct ExecutionLimits: Sendable, Hashable {
  public var maxIterations: Int
  public var maxToolCalls: Int
  public var maxDuration: Duration
  /// Deadline for one model call. A single `respond()` hung for over five minutes in Phase 0
  /// (findings §12), so a per-run limit alone is not enough.
  public var maxModelCallDuration: Duration
  /// Cap on the context the runtime will assemble. Nil means the provider's full window.
  public var maxContextTokens: Int?

  public init(
    maxIterations: Int = 8,
    maxToolCalls: Int = 16,
    maxDuration: Duration = .seconds(120),
    maxModelCallDuration: Duration = .seconds(60),
    maxContextTokens: Int? = nil
  ) {
    self.maxIterations = maxIterations
    self.maxToolCalls = maxToolCalls
    self.maxDuration = maxDuration
    self.maxModelCallDuration = maxModelCallDuration
    self.maxContextTokens = maxContextTokens
  }

  public static let `default` = ExecutionLimits()

  /// The first problem with these limits, if any.
  public var issue: ConfigurationIssue? {
    if maxIterations < 1 { return .invalidLimit("maxIterations must be at least 1") }
    if maxToolCalls < 0 { return .invalidLimit("maxToolCalls must not be negative") }
    if maxDuration <= .zero { return .invalidLimit("maxDuration must be positive") }
    if maxModelCallDuration <= .zero {
      return .invalidLimit("maxModelCallDuration must be positive")
    }
    if let tokens = maxContextTokens, tokens < 1 {
      return .invalidLimit("maxContextTokens must be positive")
    }
    return nil
  }
}
