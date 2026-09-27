import LocalAgentKitCore
import Testing

@testable import LocalAgentKitRuntime

private struct FixedGate: PermissionGate {
  let decision: PermissionDecision
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision { decision }
}

private actor CountingGate: PermissionGate {
  private(set) var asked = 0
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
    asked += 1
    return .approved
  }
}

private func descriptor(_ permission: ToolPermission) -> ToolDescriptor {
  ToolDescriptor(
    name: "t", description: "d", schema: .empty, permission: permission, isParallelSafe: true,
    isCancellable: true)
}

@Suite struct PermissionManagerTests {
  @Test(arguments: [ToolPermission.none, .readOnly])
  func atOrBelowReadOnlyIsApprovedWithoutTheGate(tier: ToolPermission) async {
    let gate = CountingGate()
    let manager = PermissionManager(gate: gate)
    let decision = await manager.authorize(ToolCall(id: "1", name: "t"), tool: descriptor(tier))
    #expect(decision == .approved)
    #expect(await gate.asked == 0)
  }

  @Test(arguments: [ToolPermission.userConfirmation, .sensitive, .destructive])
  func aboveReadOnlyAsksTheGate(tier: ToolPermission) async {
    let gate = CountingGate()
    let manager = PermissionManager(gate: gate)
    _ = await manager.authorize(ToolCall(id: "1", name: "t"), tool: descriptor(tier))
    #expect(await gate.asked == 1)
  }

  @Test func aboveReadOnlyWithNoGateIsDenied() async {
    let manager = PermissionManager()
    let decision = await manager.authorize(
      ToolCall(id: "1", name: "t"), tool: descriptor(.destructive))
    #expect(decision == .denied)
  }

  @Test func theGatesDecisionIsPassedThrough() async {
    let approved = PermissionManager(gate: FixedGate(decision: .approved))
    let denied = PermissionManager(gate: FixedGate(decision: .denied))
    let call = ToolCall(id: "1", name: "t")
    #expect(await approved.authorize(call, tool: descriptor(.sensitive)) == .approved)
    #expect(await denied.authorize(call, tool: descriptor(.sensitive)) == .denied)
  }
}
