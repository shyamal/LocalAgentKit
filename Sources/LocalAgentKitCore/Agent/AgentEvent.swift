/// A step the agent intends to take. Planners refine this in M1-RT-11.
public struct PlanStep: Sendable, Hashable, Identifiable {
  /// Stable identifier used to correlate this plan step with UI state.
  public var id: String
  /// Human-readable description of the intended work.
  public var summary: String
  /// The expected tool name, or nil for a step without a declared tool.
  public var toolName: String?

  /// Creates a displayable step with an identifier, summary and optional tool name.
  public init(id: String, summary: String, toolName: String? = nil) {
    self.id = id
    self.summary = summary
    self.toolName = toolName
  }
}

/// The ordered steps presented to observers when a run is planned.
public struct AgentPlan: Sendable, Hashable {
  /// Intended work in execution order.
  public var steps: [PlanStep]

  /// Creates a plan from its ordered display steps.
  public init(steps: [PlanStep]) {
    self.steps = steps
  }
}

/// The final result of a run.
public struct AgentResponse: Sendable, Hashable {
  /// The final answer returned by the planner.
  public var text: String
  /// Number of planner decisions made during the run.
  public var iterations: Int
  /// Number of executor invocations attempted, including failures and repaired-call attempts.
  public var toolCallCount: Int

  /// Creates an answer with the run's iteration and tool-call counts.
  public init(text: String, iterations: Int, toolCallCount: Int) {
    self.text = text
    self.iterations = iterations
    self.toolCallCount = toolCallCount
  }
}

/// How full the context window is, reported before every model call (NFR context).
public struct ContextUtilization: Sendable, Hashable {
  /// Input tokens used by the assembled model request.
  public var usedTokens: Int
  /// Context-window token limit used to calculate utilization.
  public var limitTokens: Int
  /// True when the budgeter trimmed or summarized to fit.
  public var wasTrimmed: Bool

  /// Creates a context measurement and records whether fitting changed the input.
  public init(usedTokens: Int, limitTokens: Int, wasTrimmed: Bool = false) {
    self.usedTokens = usedTokens
    self.limitTokens = limitTokens
    self.wasTrimmed = wasTrimmed
  }

  /// Used tokens divided by the limit; returns zero for a non-positive limit.
  public var fraction: Double {
    limitTokens > 0 ? Double(usedTokens) / Double(limitTokens) : 0
  }
}

/// Everything observable about a run (FR-019), consumable through `AsyncStream`.
public enum AgentEvent: Sendable {
  /// A host-owned ingestion job changed state; these snapshots use the job's separate stream.
  case ingestionProgress(IngestionProgress)
  /// A new goal has started executing.
  case started
  /// Attachment normalization progress; counts do not guarantee prompt inclusion.
  case inputProcessingProgress(processed: Int, total: Int)
  /// The runtime is about to request the next planner decision.
  case thinking
  /// The initial plan is available for display.
  case planCreated(AgentPlan)
  /// Task facts changed or were reset for a new run. This is an in-memory value snapshot.
  case workingMemoryUpdated(WorkingMemory)
  /// Persistent memories selected before fitting; this count does not guarantee prompt inclusion.
  case memoriesRetrieved(count: Int)
  /// Best-effort persistent retrieval failed; the run continues without those memories.
  case memoryRetrievalFailed(AgentError)
  /// Context fitting produced a utilization measurement before a model call.
  case contextUtilization(ContextUtilization)
  /// Initial thermal status or a sampled change at a work boundary, when monitoring is configured.
  case thermalStateChanged(ThermalStatus)
  /// The executor received a tool call, before argument validation or authorization.
  case toolRequested(ToolCall)
  /// The run is suspended until the app resolves this call.
  case permissionRequired(ToolCall)
  /// Validation and authorization succeeded; tool execution is starting.
  case toolStarted(ToolCall)
  /// The tool returned a result correlated with its call.
  case toolCompleted(ToolResult)
  /// The completed tool call and result are ready for planner observation.
  case observationReceived(ToolObservation)
  /// An append-only provisional answer fragment, not necessarily one tokenizer token.
  /// Only explicitly marked, tool-free answer requests stream; discard provisional text on failure.
  case responseToken(String)
  /// The run is suspended until the app answers.
  case clarificationRequested(String)
  /// The run ended with a terminal policy refusal.
  case guardrailRefused(GuardrailRefusal)
  /// The run completed successfully with a final answer.
  case completed(AgentResponse)
  /// The run failed with a typed error.
  case error(AgentError)
}
