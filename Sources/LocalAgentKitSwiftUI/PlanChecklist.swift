import LocalAgentKitCore

/// An event-derived presentation of the latest plan, not a scheduler or execution ledger.
/// Results do not prove step success: an empty result may lead to a retry or alternative.
public struct PlanChecklist: Sendable {
  /// Evidence available for one displayed step.
  public enum Status: String, Sendable {
    /// No correlated activity has arrived.
    case pending = "Pending"
    /// The executor received a call; validation may still fail.
    case requested = "Preparing"
    /// A correlated call needs human approval.
    case awaitingPermission = "Awaiting approval"
    /// A correlated tool is executing.
    case running = "Running"
    /// A tool returned; recovery or further work may follow.
    case resultReceived = "Result received"
    /// The run ended without a correlated tool result for this step.
    case notObserved = "Not observed"
    /// The run failed, was refused or cancelled before this step returned.
    case stopped = "Stopped"
    /// A successful run ended; this non-tool step has no finer-grained events.
    case runFinished = "Run finished"
  }

  /// A row uses its presentation position as identity, tolerating duplicate custom step IDs.
  public struct Row: Identifiable, Sendable {
    /// Position in the latest plan.
    public let id: Int
    /// Declared summary, tool and dependency IDs.
    public let step: PlanStep
    /// Latest correlated activity, without inferred skipping or success.
    public fileprivate(set) var status: Status
  }

  /// Latest plan rows. Revisions replace the plan and preserve only unchanged rows' evidence.
  public private(set) var rows: [Row] = []
  private struct Activity: Sendable {
    let step: PlanStep
    let status: Status
  }
  private var calls: [String: Activity] = [:]
  private var ended = false

  /// Creates empty run-local presentation state.
  public init() {}

  mutating func receive(_ event: AgentEvent) {
    if case .started = event { ended = false }
    guard !ended else { return }
    switch event {
    case .started:
      rows = []
      calls = [:]
    case .planCreated(let plan):
      let old = rows
      rows = plan.steps.enumerated().map { index, step in
        let matches = old.filter { $0.step == step }
        return Row(id: index, step: step, status: matches.count == 1 ? matches[0].status : .pending)
      }
    case .toolRequested(let call): update(call, .requested)
    case .permissionRequired(let call): update(call, .awaitingPermission)
    case .toolStarted(let call): update(call, .running)
    case .toolCompleted(let result):
      guard let activity = calls.removeValue(forKey: result.callID) else { return }
      let remaining = calls.values.filter { $0.step == activity.step }.map(\.status)
      let status: Status =
        remaining.contains(.running)
        ? .running
        : remaining.contains(.awaitingPermission)
          ? .awaitingPermission
          : remaining.isEmpty ? .resultReceived : .requested
      set(activity.step, status)
    case .completed:
      ended = true
      for index in rows.indices where rows[index].status != .resultReceived {
        rows[index].status = rows[index].step.toolName == nil ? .runFinished : .notObserved
      }
      calls = [:]
    case .error, .guardrailRefused:
      ended = true
      for index in rows.indices where rows[index].status != .resultReceived {
        rows[index].status = .stopped
      }
      calls = [:]
    default: break
    }
  }

  private mutating func update(_ call: ToolCall, _ status: Status) {
    guard let id = call.planStepID else { return }
    let matches = rows.filter { $0.step.id == id }
    guard matches.count == 1 else { return }
    let step = matches[0].step
    calls[call.id] = Activity(step: step, status: status)
    set(step, status)
  }

  private mutating func set(_ step: PlanStep, _ status: Status) {
    let matches = rows.indices.filter { rows[$0].step == step }
    guard matches.count == 1, let index = matches.first else { return }
    rows[index].status = status
  }
}
