/// Whether the agent may use the network (FR-023). Explicit, never implicit.
public enum NetworkPolicy: Sendable, Hashable {
  /// Offline is a guarantee: a component that requires the network is a construction error.
  case never
  case allowed
}

/// Which planner drives multi-step goals. A one-line change, by design (decision 0002).
public enum PlannerChoice: Sendable, Hashable {
  /// Deterministic control flow, the model consulted per decision. The v0.1 default.
  case stateMachine
  /// The model emits and revises whole plans. Promoted only if M5-03 clears the >95% bar.
  case modelDriven
}

/// Security settings. The permission tiers are not configurable here: nothing above `.readOnly`
/// executes without confirmation, and no flag downgrades that (PRD §19).
public struct SecurityPolicy: Sendable, Hashable {
  /// Append sensitive tool executions to the audit log (FR-022).
  public var auditSensitiveExecutions: Bool

  public init(auditSensitiveExecutions: Bool = true) {
    self.auditSensitiveExecutions = auditSensitiveExecutions
  }

  public static let `default` = SecurityPolicy()
}

/// Everything an agent is built from (FR-001).
///
/// There is no `.default`: Core cannot name a concrete model, so the model is required.
public struct AgentConfiguration: Sendable {
  public var model: any LocalModelProvider
  public var memory: (any MemoryStore)?
  public var embedding: (any EmbeddingProvider)?
  public var vectorStore: (any VectorStore)?
  public var limits: ExecutionLimits
  public var security: SecurityPolicy
  public var networkPolicy: NetworkPolicy
  public var planner: PlannerChoice

  public init(
    model: any LocalModelProvider,
    memory: (any MemoryStore)? = nil,
    embedding: (any EmbeddingProvider)? = nil,
    vectorStore: (any VectorStore)? = nil,
    limits: ExecutionLimits = .default,
    security: SecurityPolicy = .default,
    networkPolicy: NetworkPolicy = .never,
    planner: PlannerChoice = .stateMachine
  ) {
    self.model = model
    self.memory = memory
    self.embedding = embedding
    self.vectorStore = vectorStore
    self.limits = limits
    self.security = security
    self.networkPolicy = networkPolicy
    self.planner = planner
  }
}
