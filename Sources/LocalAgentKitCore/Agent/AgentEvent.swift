/// A step the agent intends to take. Planners refine this in M1-RT-11.
public struct PlanStep: Sendable, Hashable, Identifiable {
  public var id: String
  public var summary: String
  public var toolName: String?

  public init(id: String, summary: String, toolName: String? = nil) {
    self.id = id
    self.summary = summary
    self.toolName = toolName
  }
}

public struct AgentPlan: Sendable, Hashable {
  public var steps: [PlanStep]

  public init(steps: [PlanStep]) {
    self.steps = steps
  }
}

/// The final result of a run.
public struct AgentResponse: Sendable, Hashable {
  public var text: String
  public var iterations: Int
  public var toolCallCount: Int

  public init(text: String, iterations: Int, toolCallCount: Int) {
    self.text = text
    self.iterations = iterations
    self.toolCallCount = toolCallCount
  }
}

/// How full the context window is, reported before every model call (NFR context).
public struct ContextUtilization: Sendable, Hashable {
  public var usedTokens: Int
  public var limitTokens: Int
  /// True when the budgeter trimmed or summarized to fit.
  public var wasTrimmed: Bool

  public init(usedTokens: Int, limitTokens: Int, wasTrimmed: Bool = false) {
    self.usedTokens = usedTokens
    self.limitTokens = limitTokens
    self.wasTrimmed = wasTrimmed
  }

  public var fraction: Double {
    limitTokens > 0 ? Double(usedTokens) / Double(limitTokens) : 0
  }
}

/// Everything observable about a run (FR-019), consumable through `AsyncStream`.
public enum AgentEvent: Sendable {
  case started
  case thinking
  case planCreated(AgentPlan)
  case contextUtilization(ContextUtilization)
  case toolRequested(ToolCall)
  /// The run is suspended until the app resolves this call.
  case permissionRequired(ToolCall)
  case toolStarted(ToolCall)
  case toolCompleted(ToolResult)
  case observationReceived(ToolObservation)
  case responseToken(String)
  /// The run is suspended until the app answers.
  case clarificationRequested(String)
  case guardrailRefused(GuardrailRefusal)
  case completed(AgentResponse)
  case error(AgentError)
}
