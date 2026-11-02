import Foundation
import LocalAgentKitCore
import OSLog
import Synchronization

/// Opt-in unified logging and correlated signposts for runtime operation intervals.
///
/// Records only fixed operation labels and generated IDs, never prompts, tool names, arguments,
/// results or error messages. Logging uses debug level. Signposts are named `AgentOperation` and
/// carry operation/run/interval metadata. Enable signpost recording in Instruments to see them.
/// A short mutex protects interval state; no lock is held across an await or human-input wait.
public final class OSLogRuntimeInstrumentation: RuntimeInstrumentation {
  private struct ActiveInterval {
    let runID: UUID
    let operation: RuntimeOperation
    let state: OSSignpostIntervalState
  }

  private let logger: Logger
  private let signposter: OSSignposter
  private let active = Mutex<[UUID: ActiveInterval]>([:])

  /// Creates a local logging sink; subsystem and category should be static app identifiers.
  /// Defaults to subsystem `org.localagentkit` and category `Runtime`.
  public init(subsystem: String = "org.localagentkit", category: String = "Runtime") {
    let logger = Logger(subsystem: subsystem, category: category)
    self.logger = logger
    self.signposter = OSSignposter(logger: logger)
  }

  /// Emits a debug boundary and starts or ends a signpost with a unique signpost ID.
  /// Duplicate begins and unmatched ends do not create additional signpost intervals.
  public func record(_ event: RuntimeTraceEvent) {
    let operation = event.operation.rawValue
    let phase = event.phase.rawValue
    let run = event.runID.uuidString
    let interval = event.intervalID.uuidString
    logger.debug(
      "\(operation, privacy: .public) \(phase, privacy: .public) run=\(run, privacy: .public) interval=\(interval, privacy: .public)"
    )
    active.withLock { states in
      switch event.phase {
      case .began:
        guard states[event.intervalID] == nil else { return }
        let state = signposter.beginInterval(
          "AgentOperation", id: signposter.makeSignpostID(),
          "operation=\(operation, privacy: .public) run=\(run, privacy: .public) interval=\(interval, privacy: .public)"
        )
        states[event.intervalID] = ActiveInterval(
          runID: event.runID, operation: event.operation, state: state)
      case .ended:
        guard let current = states[event.intervalID], current.operation == event.operation,
          current.runID == event.runID
        else { return }
        states.removeValue(forKey: event.intervalID)
        signposter.endInterval("AgentOperation", current.state)
      }
    }
  }

  var activeIntervalCount: Int { active.withLock { $0.count } }
}
