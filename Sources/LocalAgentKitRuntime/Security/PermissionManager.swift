import LocalAgentKitCore

/// Enforces the permission tiers (FR-009): nothing above `.readOnly` runs without explicit human
/// confirmation, and no configuration can widen that. This — not prompt inspection or heuristic
/// injection detection — is the primary defense against a manipulated model attempting an
/// unintended action (PRD §19).
///
/// A single, named place for the rule `ToolExecutor` enforces, so it reads as policy rather than
/// as inline control flow.
public struct PermissionManager: Sendable {
  private let gate: (any PermissionGate)?

  /// - Parameter gate: With nil, every tool above `.readOnly` is denied outright.
  public init(gate: (any PermissionGate)? = nil) {
    self.gate = gate
  }

  /// - Returns: `.approved` for `.none`/`.readOnly` without ever consulting the gate. For
  ///   anything above that, the gate's decision, or `.denied` if none is configured.
  public func authorize(_ call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
    guard tool.permission.requiresConfirmation else { return .approved }
    return await gate?.decide(for: call, tool: tool) ?? .denied
  }
}
