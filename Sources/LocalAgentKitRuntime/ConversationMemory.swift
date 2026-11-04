import Foundation
import LocalAgentKitCore

/// Holds one ongoing conversation across runs (FR-011's Conversation Memory), so a caller does
/// not have to track and pass `conversation` to `AgentRuntime.run` by hand on every turn.
/// In-memory by default. Explicit restore/checkpoint operations support persistence through
/// Core ConversationStore; automatic demo resume is separate (M2-14).
///
/// Only the goal and the final answer of a *completed* run are remembered — not tool traffic
/// within that run, which already did its job there, and not a run that errored, refused, or was
/// cancelled. This matches what `AgentContext.recentConversationText` already shows the planner:
/// recent user/assistant text, not tool calls.
///
/// **Turn assembly and trimming under the budgeter's conversation share (M1-ME-02):** stored
/// history is capped to a small multiple of the approximate conversation share so it cannot grow
/// unbounded across a long session; once it is exceeded, the oldest half of the turns is
/// replaced with a summary using the same `ConversationSummarizer` `ContextBudgeter` uses. This
/// is a coarse, cross-run cap — `ContextBudgeter` still does its own finer, per-request trim on
/// top of whatever history comes out of here.
public actor ConversationMemory {
  private var messages: [ModelMessage] = []
  private var revision = 0
  private var checkpointInProgress = false
  private let approximateShareTokens: Int
  private let retentionMultiple: Int
  private let summarizer: any ConversationSummarizer

  /// - Parameters:
  ///   - approximateShareTokens: A rough estimate of `ContextBudgeter`'s conversation share.
  ///     Doesn't need to be exact — it only sizes when cross-run pruning kicks in.
  ///   - summarizer: Compacts older messages when retention limits are reached.
  ///   - retentionMultiple: History is pruned once it exceeds this many multiples of the share.
  public init(
    approximateShareTokens: Int = 1600, retentionMultiple: Int = 4,
    summarizer: any ConversationSummarizer = ExtractiveSummarizer()
  ) {
    self.approximateShareTokens = max(1, approximateShareTokens)
    self.retentionMultiple = max(1, retentionMultiple)
    self.summarizer = summarizer
  }

  /// Restores a validated checkpoint before exposing a new memory instance. Missing IDs start
  /// empty. The app must retain the same conversationID and use the same storage after relaunch.
  /// - Parameters:
  ///   - store: Checkpoint backend; local-only by default policy.
  ///   - conversationID: Stable app-owned conversation identity.
  ///   - approximateShareTokens: Coarse history retention share, as in the initializer.
  ///   - retentionMultiple: Retention multiplier, as in the initializer.
  ///   - summarizer: Compacts restored history if it exceeds the retention cap.
  ///   - networkPolicy: Rejects a network-requiring backend under .never before any I/O.
  /// - Throws: Typed memory/configuration errors or cancellation.
  public static func restore(
    from store: any ConversationStore, conversationID: UUID,
    approximateShareTokens: Int = 1600, retentionMultiple: Int = 4,
    summarizer: any ConversationSummarizer = ExtractiveSummarizer(),
    networkPolicy: NetworkPolicy = .never
  ) async throws -> ConversationMemory {
    try checkPersistencePolicy(store, networkPolicy)
    do {
      if Task.isCancelled { throw AgentError.cancelled }
      let snapshot = try await store.load(conversationID: conversationID)
      if Task.isCancelled { throw AgentError.cancelled }
      if let snapshot {
        guard snapshot.conversationID == conversationID else {
          throw AgentError.memoryFailure(
            "Conversation checkpoint identity does not match the request.")
        }
        try snapshot.validate()
      }
      let memory = ConversationMemory(
        approximateShareTokens: approximateShareTokens, retentionMultiple: retentionMultiple,
        summarizer: summarizer)
      await memory.install(snapshot?.messages ?? [])
      if Task.isCancelled { throw AgentError.cancelled }
      return memory
    } catch { throw persistenceError(error) }
  }

  /// Explicitly saves the current completed history. Call after awaiting runtime.run, not from
  /// its completed event, which can precede history recording. Failed writes preserve local
  /// history and the backend's last committed checkpoint. Only one checkpoint may be in flight
  /// per ConversationMemory instance; callers should await each save before starting another.
  /// - Parameters:
  ///   - store: Backend replacing a complete checkpoint atomically.
  ///   - conversationID: Identity to save; the app controls session ownership.
  ///   - networkPolicy: Defaults to local-only .never, independently of agent model policy.
  /// - Throws: Typed memory/configuration errors or cancellation. Commits already in progress
  ///   may complete despite cancellation, according to the backend's contract.
  public func checkpoint(
    to store: any ConversationStore, conversationID: UUID, networkPolicy: NetworkPolicy = .never
  ) async throws {
    try Self.checkPersistencePolicy(store, networkPolicy)
    if Task.isCancelled { throw AgentError.cancelled }
    guard !checkpointInProgress else {
      throw AgentError.memoryFailure("A conversation checkpoint is already in progress.")
    }
    checkpointInProgress = true
    defer { checkpointInProgress = false }
    let snapshot = ConversationSnapshot(conversationID: conversationID, messages: messages)
    do {
      try snapshot.validate()
      try await store.save(snapshot)
      if Task.isCancelled { throw AgentError.cancelled }
    } catch { throw Self.persistenceError(error) }
  }

  private func install(_ history: [ModelMessage]) async {
    revision &+= 1
    messages = history
    await pruneIfNeeded()
  }

  private static func checkPersistencePolicy(
    _ store: any ConversationStore, _ policy: NetworkPolicy
  ) throws {
    if policy == .never && store.requiresNetwork {
      throw AgentError.invalidConfiguration(
        .networkRequiredButForbidden(component: "conversationStore"))
    }
  }

  private static func persistenceError(_ error: any Error) -> AgentError {
    if let error = error as? AgentError { return error }
    if error is CancellationError { return .cancelled }
    return .memoryFailure("Conversation checkpoint operation failed: \(error.localizedDescription)")
  }

  /// Everything remembered so far, oldest first — ready to pass as `AgentRuntime.run`'s
  /// `conversation` parameter.
  public func history() -> [ModelMessage] {
    messages
  }

  /// Appends one completed turn, then prunes if the stored history has grown too large.
  public func recordTurn(goal: String, answer: String) async {
    revision &+= 1
    messages.append(ModelMessage(role: .user, content: goal))
    messages.append(ModelMessage(role: .assistant, content: answer))
    await pruneIfNeeded()
  }

  /// Forgets everything — for starting a new conversation.
  public func reset() {
    revision &+= 1
    messages.removeAll()
  }

  private func pruneIfNeeded() async {
    let expectedRevision = revision
    let estimate = messages.reduce(0) { $0 + TokenEstimator.tokens($1) }
    guard estimate > approximateShareTokens * retentionMultiple else { return }
    let turns = ContextBudgeter.turns(of: messages)
    guard turns.count > 1 else { return }

    let cut = max(1, turns.count / 2)
    let older = turns.prefix(cut).flatMap { $0 }
    let recent = turns.suffix(turns.count - cut).flatMap { $0 }
    guard
      let summaryText = try? await summarizer.summarize(
        Array(older), maxTokens: approximateShareTokens / 2)
    else { return }
    guard revision == expectedRevision else { return }
    revision &+= 1
    messages = [ModelMessage(role: .system, content: summaryText)] + recent
  }
}
