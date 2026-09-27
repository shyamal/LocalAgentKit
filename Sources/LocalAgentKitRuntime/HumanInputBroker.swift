import LocalAgentKitCore

/// Holds the run suspended while a human decides (FR-010, M1-RT-10).
///
/// Suspension is a continuation: no thread and no lock is held while waiting. Everything that
/// can end the wait (an answer, cancellation, the run finishing) resumes the continuation exactly
/// once, so nothing leaks and nothing hangs.
actor HumanInputBroker: PermissionGate {
  private var permissions: [String: CheckedContinuation<PermissionDecision, Never>] = [:]
  private var clarification: CheckedContinuation<String?, Never>?
  private var cancelledIDs: Set<String> = []

  var pendingPermissionCallIDs: [String] { permissions.keys.sorted() }
  var isAwaitingClarification: Bool { clarification != nil }

  // MARK: Permission

  /// Suspends until `resolve` is called. A cancelled wait answers `.denied`; the executor then
  /// reports the cancellation, so nothing runs.
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
    await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<PermissionDecision, Never>) in
        if Task.isCancelled {
          continuation.resume(returning: .denied)
          return
        }
        permissions[call.id] = continuation
      }
    } onCancel: {
      Task { await self.resolve(callID: call.id, decision: .denied) }
    }
  }

  /// - Returns: False if no such request is waiting, e.g. it was already answered.
  @discardableResult
  func resolve(callID: String, decision: PermissionDecision) -> Bool {
    guard let continuation = permissions.removeValue(forKey: callID) else { return false }
    continuation.resume(returning: decision)
    return true
  }

  // MARK: Clarification

  /// Suspends until `answer` is called. Returns nil if the wait was cancelled.
  func awaitClarification() async -> String? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
        if Task.isCancelled {
          continuation.resume(returning: nil)
          return
        }
        clarification = continuation
      }
    } onCancel: {
      Task { await self.answer(nil) }
    }
  }

  @discardableResult
  func answer(_ text: String?) -> Bool {
    guard let continuation = clarification else { return false }
    clarification = nil
    continuation.resume(returning: text)
    return true
  }

  /// Ends every wait. Called when a run finishes, so no continuation is ever left dangling.
  func cancelAll() {
    for callID in Array(permissions.keys) { resolve(callID: callID, decision: .denied) }
    answer(nil)
  }
}

/// Adds the time a human took back to the run's budget.
struct TimedGate: PermissionGate {
  let inner: any PermissionGate
  let clock: RunClock

  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
    let start = ContinuousClock.now
    let decision = await inner.decide(for: call, tool: tool)
    await clock.extend(by: ContinuousClock.now - start)
    return decision
  }
}
