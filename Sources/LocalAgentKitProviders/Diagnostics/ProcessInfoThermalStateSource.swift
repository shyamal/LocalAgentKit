import Foundation
import LocalAgentKitCore

/// Samples ProcessInfo thermal pressure locally at each runtime work checkpoint.
/// No background observer is retained; changes are observed before the next unit of work.
public struct ProcessInfoThermalStateSource: ThermalStateSource {
  /// Creates a stateless source backed by the current process's system thermal state.
  public init() {}

  /// Maps the system's current thermal snapshot; future cases map conservatively to unknown.
  public var state: AgentThermalState {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: .nominal
    case .fair: .fair
    case .serious: .serious
    case .critical: .critical
    @unknown default: .unknown
    }
  }
}
