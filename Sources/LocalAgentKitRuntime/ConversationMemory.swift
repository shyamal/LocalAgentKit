import LocalAgentKitCore

/// Holds one ongoing conversation across runs (FR-011's Conversation Memory), so a caller does
/// not have to track and pass `conversation` to `AgentRuntime.run` by hand on every turn.
/// In-memory only for v0.1; SwiftData persistence is a v0.2 concern (M2-02), the same deferral
/// `PLANNING.md` §2.2 already notes for `MemoryStore`.
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
  private let approximateShareTokens: Int
  private let retentionMultiple: Int
  private let summarizer: any ConversationSummarizer

  /// - Parameters:
  ///   - approximateShareTokens: A rough estimate of `ContextBudgeter`'s conversation share.
  ///     Doesn't need to be exact — it only sizes when cross-run pruning kicks in.
  ///   - retentionMultiple: History is pruned once it exceeds this many multiples of the share.
  public init(
    approximateShareTokens: Int = 1600, retentionMultiple: Int = 4,
    summarizer: any ConversationSummarizer = ExtractiveSummarizer()
  ) {
    self.approximateShareTokens = max(1, approximateShareTokens)
    self.retentionMultiple = max(1, retentionMultiple)
    self.summarizer = summarizer
  }

  /// Everything remembered so far, oldest first — ready to pass as `AgentRuntime.run`'s
  /// `conversation` parameter.
  public func history() -> [ModelMessage] {
    messages
  }

  /// Appends one completed turn, then prunes if the stored history has grown too large.
  public func recordTurn(goal: String, answer: String) async {
    messages.append(ModelMessage(role: .user, content: goal))
    messages.append(ModelMessage(role: .assistant, content: answer))
    await pruneIfNeeded()
  }

  /// Forgets everything — for starting a new conversation.
  public func reset() {
    messages.removeAll()
  }

  private func pruneIfNeeded() async {
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
    messages = [ModelMessage(role: .system, content: summaryText)] + recent
  }
}
