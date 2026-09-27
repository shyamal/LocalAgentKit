/// Which deadline expired.
public enum TimeoutScope: Sendable, Hashable {
  /// The whole run exceeded `ExecutionLimits.maxDuration`.
  case run
  /// A single model call exceeded `ExecutionLimits.maxModelCallDuration`.
  case modelCall
}

/// Why a configuration was rejected at construction.
public enum ConfigurationIssue: Sendable, Hashable {
  /// `NetworkPolicy.never` with a component that needs the network (FR-023).
  case networkRequiredButForbidden(component: String)
  case invalidLimit(String)
  /// A planner workflow that cannot run against the registered tools.
  case invalidWorkflow(String)
  /// A configured choice with nothing behind it, such as a planner that has not shipped.
  case unsupported(String)
}

/// Typed errors (FR-025). Each of the four execution limits has its own case.
public enum AgentError: Error, Sendable, Hashable {
  case modelUnavailable(reason: String?)
  case toolNotFound(name: String)
  case invalidArguments(tool: String, violations: [ArgumentViolation])
  case permissionDenied(tool: String)
  case toolFailed(tool: String, message: String)
  case executionTimeout(TimeoutScope)
  case maximumIterationsReached(limit: Int)
  case maximumToolCallsReached(limit: Int)
  /// What remains after both trimming and summarizing failed — not the first line of defense (R2).
  case contextLimitExceeded
  case guardrailRefusal(GuardrailRefusal)
  case loopDetected(tool: String)
  case memoryFailure(String)
  case retrievalFailure(String)
  case invalidConfiguration(ConfigurationIssue)
  /// `run` was called while another run was active. One runtime runs one goal at a time.
  case runInProgress
  case cancelled
}
