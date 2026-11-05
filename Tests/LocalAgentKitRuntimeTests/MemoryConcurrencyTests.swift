import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

@Suite struct MemoryConcurrencyTests {
  @Test(arguments: [false, true])
  func pendingCheckpointUsesItsSnapshotWhileLocalHistoryChanges(reset: Bool) async throws {
    let (ready, signal) = AsyncStream<Void>.makeStream()
    let store = ControlledCheckpointStore(pause: .save, signal: signal)
    let id = UUID()
    let memory = ConversationMemory()
    await memory.recordTurn(goal: "First question", answer: "First answer")
    let firstHistory = await memory.history()
    let task = Task { try await memory.checkpoint(to: store, conversationID: id) }
    for await _ in ready { break }
    if reset {
      await memory.reset()
    } else {
      await memory.recordTurn(goal: "New question", answer: "New answer")
    }
    let newHistory = await memory.history()
    await store.resume()
    try await task.value
    #expect(try await store.load(conversationID: id)?.messages == firstHistory)
    #expect(await memory.history() == newHistory)
    try await memory.checkpoint(to: store, conversationID: id)
    #expect(try await store.load(conversationID: id)?.messages == newHistory)
  }

  @Test func cancellationAfterBackendCommitPreservesHistoryAndReleasesCheckpointLock() async throws
  {
    let (ready, signal) = AsyncStream<Void>.makeStream()
    let store = ControlledCheckpointStore(pause: .save, signal: signal)
    let memory = ConversationMemory()
    let id = UUID()
    await memory.recordTurn(goal: "Question", answer: "Answer")
    let history = await memory.history()
    let task = Task { try await memory.checkpoint(to: store, conversationID: id) }
    for await _ in ready { break }
    task.cancel()
    await store.resume()  // Simulates a backend commit that cannot be interrupted.
    await #expect(throws: AgentError.cancelled) { try await task.value }
    #expect(await memory.history() == history)
    #expect(try await store.load(conversationID: id)?.messages == history)
    await memory.recordTurn(goal: "Next question", answer: "Next answer")
    try await memory.checkpoint(to: store, conversationID: id)
    #expect(try await store.load(conversationID: id)?.messages == memory.history())
  }

  @Test func cancellationAfterBackendLoadDoesNotExposeRestoredHistory() async throws {
    let (ready, signal) = AsyncStream<Void>.makeStream()
    let store = ControlledCheckpointStore(pause: .load, signal: signal)
    let id = UUID()
    try await store.save(
      ConversationSnapshot(
        conversationID: id,
        messages: [
          ModelMessage(role: .user, content: "Private question"),
          ModelMessage(role: .assistant, content: "Private answer"),
        ]))
    let task = Task { try await ConversationMemory.restore(from: store, conversationID: id) }
    for await _ in ready { break }
    task.cancel()
    await store.resume()
    await #expect(throws: AgentError.cancelled) { try await task.value }
    #expect(try await store.load(conversationID: id)?.messages.count == 2)
  }

  @Test(arguments: [false, true])
  func backendCancellationErrorsAreTypedEvenWhenTheCallerIsNotCancelled(load: Bool) async {
    await #expect(throws: AgentError.cancelled) {
      if load {
        _ = try await ConversationMemory.restore(
          from: CancellingCheckpointStore(), conversationID: UUID())
      } else {
        try await ConversationMemory().checkpoint(
          to: CancellingCheckpointStore(), conversationID: UUID())
      }
    }
  }

  @Test func summarizationFailureKeepsCompleteTurnsAndAllowsCheckpointing() async throws {
    let memory = ConversationMemory(
      approximateShareTokens: 10, retentionMultiple: 1, summarizer: FailingMemorySummarizer())
    await memory.recordTurn(goal: String(repeating: "first ", count: 20), answer: "Answer one")
    await memory.recordTurn(goal: String(repeating: "second ", count: 20), answer: "Answer two")
    let history = await memory.history()
    #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    let store = MockConversationStore()
    let id = UUID()
    try await memory.checkpoint(to: store, conversationID: id)
    #expect(
      try await ConversationMemory.restore(from: store, conversationID: id).history() == history)
  }

  @Test func staleSummaryCannotOverwriteANewerTurnOrSummary() async {
    let (ready, signal) = AsyncStream<Void>.makeStream()
    let summarizer = ReorderedMemorySummarizer(signal: signal)
    let memory = ConversationMemory(
      approximateShareTokens: 10, retentionMultiple: 1, summarizer: summarizer)
    await memory.recordTurn(goal: String(repeating: "first ", count: 20), answer: "First answer")
    let older = Task { await memory.recordTurn(goal: "Second question", answer: "Second answer") }
    for await _ in ready { break }
    await memory.recordTurn(goal: "Newest question", answer: "Newest answer")
    let newer = await memory.history()
    #expect(newer.last?.content == "Newest answer")
    #expect(newer.first?.content == "New summary")
    await summarizer.resumeOld()
    await older.value
    #expect(await memory.history() == newer)
  }

  @Test(arguments: [Int.max, Int.max / 2 + 1])
  func extremeRetentionConfigurationCannotOverflowOrAccidentallyPrune(share: Int) async {
    let memory = ConversationMemory(approximateShareTokens: share, retentionMultiple: 2)
    await memory.recordTurn(goal: "First", answer: "One")
    await memory.recordTurn(goal: "Second", answer: "Two")
    #expect(await memory.history().map(\.content) == ["First", "One", "Second", "Two"])
  }
}

private actor ControlledCheckpointStore: ConversationStore {
  enum Operation { case load, save }
  private let pause: Operation
  private let signal: AsyncStream<Void>.Continuation
  private var shouldPause = true
  private var continuation: CheckedContinuation<Void, Never>?
  private var snapshots: [UUID: ConversationSnapshot] = [:]
  init(pause: Operation, signal: AsyncStream<Void>.Continuation) {
    self.pause = pause
    self.signal = signal
  }
  func load(conversationID: UUID) async throws -> ConversationSnapshot? {
    await suspendOnce(.load)
    return snapshots[conversationID]
  }
  func save(_ snapshot: ConversationSnapshot) async throws {
    try snapshot.validate()
    await suspendOnce(.save)
    snapshots[snapshot.conversationID] = snapshot
  }
  func delete(conversationID: UUID) async throws { snapshots[conversationID] = nil }
  private func suspendOnce(_ operation: Operation) async {
    guard operation == pause, shouldPause else { return }
    shouldPause = false
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      signal.yield(())
    }
  }
  func resume() {
    continuation?.resume()
    continuation = nil
  }
}
private struct CancellingCheckpointStore: ConversationStore {
  func load(conversationID: UUID) async throws -> ConversationSnapshot? {
    throw CancellationError()
  }
  func save(_ snapshot: ConversationSnapshot) async throws { throw CancellationError() }
  func delete(conversationID: UUID) async throws { throw CancellationError() }
}
private struct FailingMemorySummarizer: ConversationSummarizer {
  func summarize(_ messages: [ModelMessage], maxTokens: Int) async throws -> String {
    throw AgentError.memoryFailure("Synthetic summarizer failure")
  }
}
private actor ReorderedMemorySummarizer: ConversationSummarizer {
  let signal: AsyncStream<Void>.Continuation
  var calls = 0
  var old: CheckedContinuation<String, Never>?
  init(signal: AsyncStream<Void>.Continuation) { self.signal = signal }
  func summarize(_ messages: [ModelMessage], maxTokens: Int) async throws -> String {
    calls += 1
    if calls > 1 { return "New summary" }
    return await withCheckedContinuation {
      old = $0
      signal.yield(())
    }
  }
  func resumeOld() {
    old?.resume(returning: "Stale summary")
    old = nil
  }
}
