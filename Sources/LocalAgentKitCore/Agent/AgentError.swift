/// Which deadline expired.
public enum TimeoutScope: Sendable, Hashable {
  /// The whole run exceeded `ExecutionLimits.maxDuration`.
  case run
  /// A single model call exceeded `ExecutionLimits.maxModelCallDuration`.
  case modelCall
}

/// A device capability gated by system-level authorization (Calendar, Reminders, …). Distinct
/// from ``ToolPermission``, which is the app's own tier: this is the OS's decision, not ours, and
/// it is why the error below is separate from a generic tool failure — an app can direct the user
/// to Settings instead of just reporting an error.
public enum DeviceCapability: Sendable, Hashable, CustomStringConvertible {
  case calendar
  case reminders

  public var description: String {
    switch self {
    case .calendar: "Calendar"
    case .reminders: "Reminders"
    }
  }
}

/// Why a configuration was rejected at construction.
public enum ConfigurationIssue: Sendable, Hashable, CustomStringConvertible {
  /// `NetworkPolicy.never` with a component that needs the network (FR-023).
  case networkRequiredButForbidden(component: String)
  case invalidLimit(String)
  /// A planner workflow that cannot run against the registered tools.
  case invalidWorkflow(String)
  /// A configured choice with nothing behind it, such as a planner that has not shipped.
  case unsupported(String)

  public var description: String {
    switch self {
    case .networkRequiredButForbidden(let component):
      "\(component) needs network access, but the network policy forbids it"
    case .invalidLimit(let message): message
    case .invalidWorkflow(let message): message
    case .unsupported(let message): message
    }
  }
}

/// Typed errors (FR-025). Each of the four execution limits has its own case.
public enum AgentError: Error, Sendable, Hashable, CustomStringConvertible {
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
  /// The OS denied, restricted, or never granted access to a device capability (M1-TL-06).
  case deviceAuthorizationDenied(DeviceCapability)
  case loopDetected(tool: String)
  case memoryFailure(String)
  case retrievalFailure(String)
  case invalidConfiguration(ConfigurationIssue)
  /// `run` was called while another run was active. One runtime runs one goal at a time.
  case runInProgress
  case cancelled

  /// A sentence a host app can show a person as-is, distinct from `debugDescription`-style dumps
  /// of the case and its payload. An app that wants its own copy can still switch over the case;
  /// this exists for the common path of surfacing `lastFailure` directly (as the demo app does).
  public var description: String {
    switch self {
    case .modelUnavailable(let reason):
      "The model is unavailable" + (reason.map { ": \($0)" } ?? ".")
    case .toolNotFound(let name):
      "No tool named \"\(name)\" is registered."
    case .invalidArguments(let tool, let violations):
      "\"\(tool)\" was called with invalid arguments: "
        + violations.map(\.description).joined(separator: "; ") + "."
    case .permissionDenied(let tool):
      "Permission to run \"\(tool)\" was denied."
    case .toolFailed(let tool, let message):
      "\"\(tool)\" failed: \(message)"
    case .executionTimeout(.run):
      "The request took too long and timed out."
    case .executionTimeout(.modelCall):
      "The model took too long to respond and timed out."
    case .maximumIterationsReached(let limit):
      "The request needed more than \(limit) steps, so it was stopped."
    case .maximumToolCallsReached(let limit):
      "The request needed more than \(limit) tool calls, so it was stopped."
    case .contextLimitExceeded:
      "The conversation grew too large for the model's context window."
    case .guardrailRefusal(let refusal):
      refusal.explanation ?? "The model declined to respond to this request."
    case .deviceAuthorizationDenied(let capability):
      "Access to \(capability) was not authorized. Check Settings to grant access."
    case .loopDetected(let tool):
      "\"\(tool)\" was called repeatedly without making progress, so the request was stopped."
    case .memoryFailure(let message):
      "Could not read or write conversation memory: \(message)"
    case .retrievalFailure(let message):
      "Document search failed: \(message)"
    case .invalidConfiguration(let issue):
      "Invalid configuration: \(issue)"
    case .runInProgress:
      "Another request is already running."
    case .cancelled:
      "The request was cancelled."
    }
  }
}
