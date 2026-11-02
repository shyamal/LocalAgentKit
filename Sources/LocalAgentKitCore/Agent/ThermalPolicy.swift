/// Framework-neutral device thermal pressure, sampled at runtime work boundaries.
public enum AgentThermalState: Sendable, Hashable {
  /// Normal thermal conditions.
  case nominal
  /// Elevated pressure; reduce the next model request's context allowance.
  case fair
  /// High pressure; apply a tighter context allowance.
  case serious
  /// Stop starting new model and tool work until the host retries after cooling.
  case critical
  /// A future or unrecognized platform state; conservatively treated like serious pressure.
  case unknown
}

/// Supplies a thread-safe local thermal snapshot; adapters isolate platform APIs from the runtime.
public protocol ThermalStateSource: Sendable {
  /// Declares network-backed state sources so offline construction can reject them.
  var requiresNetwork: Bool { get }
  /// Current sampled state; implementations must return promptly without blocking on I/O.
  var state: AgentThermalState { get }
}

extension ThermalStateSource {
  /// Default declaration for local device-state sampling.
  public var requiresNetwork: Bool { false }
}

/// Additional context caps applied at elevated pressure; original limits are never increased.
public struct ThermalPolicy: Sendable, Hashable {
  /// Context-window cap at fair pressure, including the answer reserve; must be positive.
  public var fairContextTokens: Int
  /// Cap at serious or unknown pressure; must be positive and no larger than the fair cap.
  public var seriousContextTokens: Int

  /// Creates elevated-pressure caps. Critical pressure always rejects new model/tool work.
  public init(fairContextTokens: Int = 3072, seriousContextTokens: Int = 2048) {
    self.fairContextTokens = fairContextTokens
    self.seriousContextTokens = seriousContextTokens
  }

  /// Uses 3072 tokens at fair and 2048 at serious pressure; critical prevents new work.
  public static let `default` = ThermalPolicy()

  /// The first invalid cap, or nil when positive and ordered from fair to serious.
  public var issue: ConfigurationIssue? {
    guard fairContextTokens > 0, seriousContextTokens > 0,
      seriousContextTokens <= fairContextTokens
    else {
      return .invalidLimit("thermal context caps must be positive and serious must not exceed fair")
    }
    return nil
  }

  /// Produces the policy status for a sampled state, independent of a model's smaller window.
  public func status(for state: AgentThermalState) -> ThermalStatus {
    let cap: Int?
    switch state {
    case .nominal, .critical: cap = nil
    case .fair: cap = fairContextTokens
    case .serious, .unknown: cap = seriousContextTokens
    }
    return ThermalStatus(state: state, contextTokenCap: cap)
  }
}

/// Sampled thermal pressure and the configured policy cap, published on state changes.
public struct ThermalStatus: Sendable, Hashable {
  /// Device pressure sampled at a work boundary.
  public let state: AgentThermalState
  /// Additional model-window cap; nil means unchanged or, at critical pressure, no work allowed.
  /// A model or execution limit may already impose a smaller cap.
  public let contextTokenCap: Int?
  /// False at critical pressure; other states permit work with any additional cap applied.
  public var allowsNewWork: Bool { state != .critical }

  /// Creates a sampled status; policy producers should use ThermalPolicy.status(for:).
  public init(state: AgentThermalState, contextTokenCap: Int?) {
    self.state = state
    self.contextTokenCap = contextTokenCap
  }
}
