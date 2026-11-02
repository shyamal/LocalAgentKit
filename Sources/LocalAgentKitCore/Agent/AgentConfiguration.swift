/// Whether the agent may use the network (FR-023). Explicit, never implicit.
public enum NetworkPolicy: Sendable, Hashable {
  /// Offline is a guarantee: a component that requires the network is a construction error.
  case never
  /// Allows components that declare a network requirement; does not force network use.
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

  /// Creates an audit policy; sensitive executions are recorded by default.
  public init(auditSensitiveExecutions: Bool = true) {
    self.auditSensitiveExecutions = auditSensitiveExecutions
  }

  /// Records confirmed executions in the runtime audit log.
  public static let `default` = SecurityPolicy()
}

/// Everything an agent is built from (FR-001).
///
/// There is no `.default`: Core cannot name a concrete model, so the model is required.
public struct AgentConfiguration: Sendable {
  /// Provider used for generation and optional token counting.
  public var model: any LocalModelProvider
  /// Reserved persistent-memory component; the current runtime does not query this store.
  /// Configure ConversationMemory on the runtime for cross-turn history.
  public var memory: (any MemoryStore)?
  /// Query embedding component; automatic retrieval requires a vector store as well.
  public var embedding: (any EmbeddingProvider)?
  /// Searchable embeddings; automatic retrieval requires an embedding provider as well.
  public var vectorStore: (any VectorStore)?
  /// Bounds one run, each model call and the assembled context.
  public var limits: ExecutionLimits
  /// Controls audit recording; cannot weaken tool permission tiers.
  public var security: SecurityPolicy
  /// Whether registered components may require network access.
  public var networkPolicy: NetworkPolicy
  /// Planner selection; model-driven mode requires an explicit planner implementation.
  public var planner: PlannerChoice

  /// Creates a configuration with a required model and optional storage, retrieval and execution policies.
  /// The runtime validates limits and declared network requirements when constructed.
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
