import Foundation

/// Fixed operation labels for diagnostics; never contains model or user text.
public enum RuntimeOperation: String, Sendable, Hashable {
  /// The active runtime execution, including time waiting for a person.
  case run
  /// Initial plan selection or generation.
  case planning
  /// A budgeted model request, including context fitting and provider generation.
  case modelCall
  /// A planned invocation, including validation, permission, repair and observation.
  case toolCall
  /// Automatic goal-based retrieval before planning; explicit search tools use tool-call spans.
  case retrieval
  /// A required human permission decision, including its suspended wait.
  case permission
  /// Waiting for an answer to a clarification question.
  case clarification
}

/// One boundary of a correlated diagnostic interval, carrying no user content.
public struct RuntimeTraceEvent: Sendable, Hashable {
  /// Whether an interval is opening or closing; an end does not imply success.
  public enum Phase: String, Sendable, Hashable {
    /// The operation is starting.
    case began
    /// The scope has exited, whether by success, error, refusal, timeout or cancellation.
    case ended
  }

  /// Correlates all operations belonging to one run, including concurrent runtimes.
  public let runID: UUID
  /// Correlates the two boundaries of a single interval.
  public let intervalID: UUID
  /// Fixed operation category; excludes tool names, arguments and transcript content.
  public let operation: RuntimeOperation
  /// The opening or closing boundary.
  public let phase: Phase

  /// Creates one boundary; producers must pair begin and end with the same IDs and operation.
  public init(runID: UUID, intervalID: UUID, operation: RuntimeOperation, phase: Phase) {
    self.runID = runID
    self.intervalID = intervalID
    self.operation = operation
    self.phase = phase
  }
}

/// An optional synchronous diagnostics sink, separate from user-facing AgentEvent streams.
///
/// Implementations must be thread-safe, return promptly, avoid reentering the runtime and never
/// block on human input. The runtime pairs intervals with defer, including failing paths.
/// Diagnostics cannot alter execution, permission decisions or error handling.
public protocol RuntimeInstrumentation: Sendable {
  /// True if diagnostics require network access; rejected by the runtime under `.never`.
  var requiresNetwork: Bool { get }
  /// Records one content-free interval boundary. Calls may arrive from concurrent runs.
  func record(_ event: RuntimeTraceEvent)
}

extension RuntimeInstrumentation {
  /// Default declaration for a local diagnostic sink.
  public var requiresNetwork: Bool { false }
}

/// Default sink that discards interval boundaries without logging or framework dependencies.
public struct NoOpRuntimeInstrumentation: RuntimeInstrumentation {
  /// Creates a sink that performs no logging.
  public init() {}

  /// Discards the diagnostic boundary.
  public func record(_ event: RuntimeTraceEvent) {}
}
