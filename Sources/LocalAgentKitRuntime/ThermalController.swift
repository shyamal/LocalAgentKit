import LocalAgentKitCore

/// Per-run observation state. Notifications are deduplicated; policy is sampled again at every check.
actor ThermalController {
  let source: any ThermalStateSource
  let policy: ThermalPolicy
  let events: EventBus
  private var previous: ThermalStatus?

  init(source: any ThermalStateSource, policy: ThermalPolicy, events: EventBus) {
    self.source = source
    self.policy = policy
    self.events = events
  }

  func checkpoint() async throws -> ThermalStatus {
    if Task.isCancelled { throw AgentError.cancelled }
    let status = policy.status(for: source.state)
    if status != previous {
      previous = status
      await events.publish(.thermalStateChanged(status))
    }
    if Task.isCancelled { throw AgentError.cancelled }
    guard status.allowsNewWork else { throw AgentError.thermalPressureTooHigh }
    return status
  }
}
