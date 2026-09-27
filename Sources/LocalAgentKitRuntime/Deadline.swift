import LocalAgentKitCore

/// Runs `operation`, giving up on it after `duration`.
///
/// Unlike a task-group timeout, this **abandons** an operation that ignores cancellation: the
/// caller is resumed with `.executionTimeout(scope)` at the deadline and the operation is
/// cancelled, but the caller does not wait for it to notice. A structured timeout would wait, and
/// a single `respond()` hung for over five minutes in Phase 0 (findings §12). The price is that a
/// truly stuck operation is left running as a leaked task until it returns.
///
/// Cancelling the caller resumes it with `.cancelled` the same way.
func withDeadline<T: Sendable>(
  _ duration: Duration, scope: TimeoutScope,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  let race = DeadlineRace<T>()
  return try await withTaskCancellationHandler {
    try await race.run(duration: duration, scope: scope, operation: operation)
  } onCancel: {
    Task { await race.cancel() }
  }
}

private actor DeadlineRace<T: Sendable> {
  private var continuation: CheckedContinuation<T, any Error>?
  private var tasks: [Task<Void, Never>] = []
  private var cancelRequested = false

  func run(
    duration: Duration, scope: TimeoutScope,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
      if cancelRequested {
        continuation.resume(throwing: AgentError.cancelled)
        return
      }
      self.continuation = continuation
      tasks.append(
        Task {
          do {
            finish(.success(try await operation()))
          } catch is CancellationError {
            finish(.failure(AgentError.cancelled))
          } catch {
            finish(.failure(error))
          }
        })
      tasks.append(
        Task {
          try? await Task.sleep(for: duration)
          if !Task.isCancelled { finish(.failure(AgentError.executionTimeout(scope))) }
        })
    }
  }

  func cancel() {
    cancelRequested = true
    finish(.failure(AgentError.cancelled))
  }

  /// The first result wins; the loser is cancelled.
  private func finish(_ result: Result<T, any Error>) {
    guard let continuation else { return }
    self.continuation = nil
    for task in tasks { task.cancel() }
    continuation.resume(with: result)
  }
}

/// How much of the run's time budget is left. Time spent waiting on a human is added back:
/// a person taking a minute to answer must not cause a timeout.
actor RunClock {
  private var deadline: ContinuousClock.Instant

  init(budget: Duration) {
    deadline = .now + budget
  }

  func remaining() -> Duration {
    deadline - .now
  }

  func extend(by duration: Duration) {
    deadline += duration
  }
}
