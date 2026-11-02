import LocalAgentKitCore
import Synchronization

/// Thread-safe recording diagnostics sink for tests, with no OSLog or model requirement.
public final class MockRuntimeInstrumentation: RuntimeInstrumentation {
  private let recorded = Mutex<[RuntimeTraceEvent]>([])
  /// Configurable network declaration for construction-policy tests; performs no network I/O.
  public let requiresNetwork: Bool

  /// Creates an empty recording sink with an optional network requirement declaration.
  public init(requiresNetwork: Bool = false) { self.requiresNetwork = requiresNetwork }

  /// Snapshot of boundaries in recording order; contains IDs and fixed labels only.
  public var events: [RuntimeTraceEvent] { recorded.withLock { $0 } }

  /// Appends one boundary synchronously; the lock is released before execution resumes.
  public func record(_ event: RuntimeTraceEvent) {
    recorded.withLock { $0.append(event) }
  }
}
