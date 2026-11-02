import LocalAgentKitCore
import Synchronization

/// Controllable thread-safe thermal state for tests, without device heating or notifications.
public final class MockThermalStateSource: ThermalStateSource {
  private let current: Mutex<AgentThermalState>
  /// Configurable declaration used to verify offline construction; no actual network is used.
  public let requiresNetwork: Bool

  /// Creates a source at the supplied state, nominal by default.
  public init(_ state: AgentThermalState = .nominal, requiresNetwork: Bool = false) {
    self.current = Mutex(state)
    self.requiresNetwork = requiresNetwork
  }

  /// Returns the most recently assigned snapshot.
  public var state: AgentThermalState { current.withLock { $0 } }

  /// Changes the snapshot seen at the next work checkpoint.
  public func setState(_ state: AgentThermalState) { current.withLock { $0 = state } }
}
