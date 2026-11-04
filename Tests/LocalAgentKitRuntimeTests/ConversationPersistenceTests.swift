import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

@Suite struct ConversationPersistenceTests {
  @Test func aNewRuntimeUsesTheRestoredCompletedHistory() async throws {
    let store = MockConversationStore()
    let id = UUID()
    let memory = ConversationMemory()
    let planner = StateMachinePlanner(
      workflow: Workflow(
        name: "answer", description: "Answer",
        steps: [.respond(instruction: "Use conversation context.")]))
    let first = try AgentRuntime(
      configuration: AgentConfiguration(
        model: ScriptedModelProvider(responses: [.text("Budget review at 10am")])),
      tools: StaticToolSource([]), planner: planner, memory: memory)
    _ = try await first.run("My meeting?")
    #expect(await store.snapshots.isEmpty)  // no implicit persistence during the agent run
    try await memory.checkpoint(to: store, conversationID: id)
    let restored = try await ConversationMemory.restore(from: store, conversationID: id)
    let model = ScriptedModelProvider(responses: [.text("Prepare the budget review")])
    let second = try AgentRuntime(
      configuration: AgentConfiguration(model: model),
      tools: StaticToolSource([]), planner: planner, memory: restored)
    _ = try await second.run("What should I prepare?")
    let request = try #require(await model.requests.first)
    #expect(request.messages.contains { $0.content == "Budget review at 10am" })
    #expect(await restored.history().count == 4)
    #expect(
      try await ConversationMemory.restore(from: store, conversationID: UUID()).history().isEmpty)
    await restored.reset()
    try await restored.checkpoint(to: store, conversationID: id)
    #expect(try await ConversationMemory.restore(from: store, conversationID: id).history().isEmpty)
  }

  @Test func failedCheckpointPreservesLocalAndPreviouslySavedHistory() async throws {
    let store = MockConversationStore()
    let id = UUID()
    let memory = ConversationMemory()
    await memory.recordTurn(goal: "First", answer: "Saved")
    try await memory.checkpoint(to: store, conversationID: id)
    let previous = await store.snapshots[id]
    await memory.recordTurn(goal: "Second", answer: "Still local")
    await #expect(throws: AgentError.memoryFailure("Write failed")) {
      try await memory.checkpoint(to: FailingStore(base: store), conversationID: id)
    }
    #expect(await memory.history().count == 4)
    #expect(await store.snapshots[id] == previous)
  }

  @Test func networkBackendsAreRejectedBeforePersistenceByDefault() async throws {
    let store = MockConversationStore(requiresNetwork: true)
    let id = UUID()
    let expected = AgentError.invalidConfiguration(
      .networkRequiredButForbidden(component: "conversationStore"))
    await #expect(throws: expected) {
      try await ConversationMemory.restore(from: store, conversationID: id)
    }
    let memory = ConversationMemory()
    await #expect(throws: expected) { try await memory.checkpoint(to: store, conversationID: id) }
    #expect(await store.snapshots.isEmpty)
    try await memory.checkpoint(to: store, conversationID: id, networkPolicy: .allowed)
    #expect(await store.snapshots[id] != nil)
  }

  @Test func cancellationBeforeCheckpointDoesNotWrite() async throws {
    let store = MockConversationStore()
    let memory = ConversationMemory()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await #expect(throws: AgentError.cancelled) {
        try await memory.checkpoint(to: store, conversationID: UUID())
      }
    }
    await task.value
    #expect(await store.snapshots.isEmpty)
  }

  @Test(arguments: [false, true])
  func restoreRejectsWrongIdentityOrIncompleteData(wrongIdentity: Bool) async {
    let id = UUID()
    let snapshot = ConversationSnapshot(
      conversationID: wrongIdentity ? UUID() : id,
      messages: wrongIdentity ? [] : [ModelMessage(role: .user, content: "Partial")])
    do {
      _ = try await ConversationMemory.restore(
        from: SnapshotStore(snapshot: snapshot), conversationID: id)
      Issue.record("Expected invalid checkpoint to fail")
    } catch let error as AgentError {
      guard case .memoryFailure = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    } catch { Issue.record("Expected typed memory failure") }
  }

  @Test func rawBackendFailuresBecomeTypedMemoryErrors() async {
    let memory = ConversationMemory()
    do {
      try await memory.checkpoint(to: RawFailureStore(), conversationID: UUID())
      Issue.record("Expected failure")
    } catch let error as AgentError {
      guard case .memoryFailure = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    } catch { Issue.record("Expected typed memory failure") }
    do {
      _ = try await ConversationMemory.restore(from: RawFailureStore(), conversationID: UUID())
      Issue.record("Expected failure")
    } catch let error as AgentError {
      guard case .memoryFailure = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    } catch { Issue.record("Expected typed memory failure") }
  }

  @Test func resetDuringSummarizationDoesNotResurrectHistory() async {
    let (ready, signal) = AsyncStream<Void>.makeStream()
    let summarizer = PausedSummarizer(signal: signal)
    let memory = ConversationMemory(
      approximateShareTokens: 10, retentionMultiple: 1, summarizer: summarizer)
    await memory.recordTurn(
      goal: String(repeating: "a", count: 80), answer: String(repeating: "b", count: 80))
    let task = Task { await memory.recordTurn(goal: "Another question", answer: "Another answer") }
    for await _ in ready { break }
    await memory.reset()
    await summarizer.resume()
    await task.value
    #expect(await memory.history().isEmpty)
  }

  @Test func overlappingCheckpointsAreRejectedInsteadOfWritingStaleHistory() async throws {
    let (ready, signal) = AsyncStream<Void>.makeStream()
    let store = PausedStore(signal: signal)
    let memory = ConversationMemory()
    let id = UUID()
    let first = Task { try await memory.checkpoint(to: store, conversationID: id) }
    for await _ in ready { break }
    await #expect(
      throws: AgentError.memoryFailure("A conversation checkpoint is already in progress.")
    ) {
      try await memory.checkpoint(to: store, conversationID: id)
    }
    await store.resume()
    try await first.value
  }
}

private struct FailingStore: ConversationStore {
  let base: MockConversationStore
  func load(conversationID: UUID) async throws -> ConversationSnapshot? {
    try await base.load(conversationID: conversationID)
  }
  func save(_ snapshot: ConversationSnapshot) async throws {
    throw AgentError.memoryFailure("Write failed")
  }
  func delete(conversationID: UUID) async throws {
    try await base.delete(conversationID: conversationID)
  }
}

private actor PausedSummarizer: ConversationSummarizer {
  let signal: AsyncStream<Void>.Continuation
  var continuation: CheckedContinuation<String, Never>?
  init(signal: AsyncStream<Void>.Continuation) { self.signal = signal }
  func summarize(_ messages: [ModelMessage], maxTokens: Int) async throws -> String {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      signal.yield(())
    }
  }
  func resume() {
    continuation?.resume(returning: "Older summary")
    continuation = nil
  }
}

private actor PausedStore: ConversationStore {
  let signal: AsyncStream<Void>.Continuation
  var continuation: CheckedContinuation<Void, Never>?
  init(signal: AsyncStream<Void>.Continuation) { self.signal = signal }
  func load(conversationID: UUID) async throws -> ConversationSnapshot? { nil }
  func save(_ snapshot: ConversationSnapshot) async throws {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      signal.yield(())
    }
  }
  func delete(conversationID: UUID) async throws {}
  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

private struct SnapshotStore: ConversationStore {
  let snapshot: ConversationSnapshot
  func load(conversationID: UUID) async throws -> ConversationSnapshot? { snapshot }
  func save(_ snapshot: ConversationSnapshot) async throws {}
  func delete(conversationID: UUID) async throws {}
}
private struct RawFailure: Error {}
private struct RawFailureStore: ConversationStore {
  func load(conversationID: UUID) async throws -> ConversationSnapshot? { throw RawFailure() }
  func save(_ snapshot: ConversationSnapshot) async throws { throw RawFailure() }
  func delete(conversationID: UUID) async throws { throw RawFailure() }
}
