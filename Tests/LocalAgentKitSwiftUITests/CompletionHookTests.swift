import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitSwiftUI
import LocalAgentKitTesting
import Testing

@MainActor
@Suite struct CompletionHookTests {
  @Test func hookSeesRecordedHistoryAndBlocksNewSendsUntilItFinishes() async throws {
    let memory = ConversationMemory()
    let model = ScriptedModelProvider(responses: [.text("Saved answer")])
    let runtime = try answerRuntime(model, memory: memory)
    let (ready, signal) = AsyncStream<Void>.makeStream()
    let hook = PausedCompletion(signal: signal)
    let restored = [
      AgentViewModel.Turn(role: .user, text: "Earlier"), .init(role: .assistant, text: "Reply"),
    ]
    let viewModel = AgentViewModel(
      runtime: runtime, initialTurns: restored,
      onRunCompleted: {
        await hook.pause(history: memory.history())
      })
    #expect(viewModel.turns == restored)
    viewModel.send("New goal")
    for await _ in ready { break }
    #expect(await hook.history.map(\.content) == ["New goal", "Saved answer"])
    #expect(viewModel.isRunning)
    viewModel.send("Must not overlap")
    #expect(!viewModel.turns.contains { $0.text == "Must not overlap" })
    await hook.resume()
    await waitForCompletion { !viewModel.isRunning }
    #expect(viewModel.state == .idle)
    #expect(viewModel.turns.map(\.text) == ["Earlier", "Reply", "New goal", "Saved answer"])
    #expect(await model.requests.count == 1)
    await runtime.finishEvents()
  }

  @Test func completionFailureKeepsReplyVisibleAndCanRecoverOnNextCompletedTurn() async throws {
    let model = ScriptedModelProvider(responses: [.text("First reply"), .text("Second reply")])
    let runtime = try answerRuntime(model)
    let hook = FailsOnceCompletion()
    let viewModel = AgentViewModel(runtime: runtime, onRunCompleted: { try await hook.complete() })
    viewModel.send("First")
    await waitForCompletion { !viewModel.isRunning }
    #expect(viewModel.turns.last?.text == "First reply")
    #expect(viewModel.lastFailure?.contains("Synthetic save failure") == true)
    viewModel.send("Second")
    await waitForCompletion { !viewModel.isRunning }
    #expect(await hook.calls == 2)
    #expect(viewModel.lastFailure == nil)
    #expect(viewModel.turns.last?.text == "Second reply")
    await runtime.finishEvents()
  }

  @Test(arguments: ["error", "refusal", "cancelled"])
  func unsuccessfulRunsNeverInvokeCompletionHook(outcome: String) async throws {
    let step: ScriptedModelProvider.Step
    switch outcome {
    case "refusal": step = .respond(.refused(GuardrailRefusal(explanation: "Declined")))
    case "cancelled": step = .fail(.cancelled)
    default: step = .fail(.modelUnavailable(reason: "Unavailable"))
    }
    let memory = ConversationMemory()
    let runtime = try answerRuntime(ScriptedModelProvider([step]), memory: memory)
    let hook = CompletionCounter()
    let viewModel = AgentViewModel(runtime: runtime, onRunCompleted: { await hook.complete() })
    viewModel.send("Run")
    await waitForCompletion { !viewModel.isRunning }
    #expect(await hook.calls == 0)
    #expect(await memory.history().isEmpty)
    #expect(viewModel.lastFailure != nil)
    await runtime.finishEvents()
  }
}

private func answerRuntime(_ model: any LocalModelProvider, memory: ConversationMemory? = nil)
  throws -> AgentRuntime
{
  try AgentRuntime(
    configuration: AgentConfiguration(model: model), tools: StaticToolSource([]),
    planner: StateMachinePlanner(
      workflow: Workflow(
        name: "answer", description: "Answer", steps: [.respond(instruction: "Reply")])),
    memory: memory)
}
@MainActor private func waitForCompletion(_ condition: () -> Bool) async {
  let deadline = ContinuousClock.now + .seconds(5)
  while !condition(), ContinuousClock.now < deadline { await Task.yield() }
  #expect(condition())
}
private actor PausedCompletion {
  let signal: AsyncStream<Void>.Continuation
  var history: [ModelMessage] = []
  var continuation: CheckedContinuation<Void, Never>?
  init(signal: AsyncStream<Void>.Continuation) { self.signal = signal }
  func pause(history: [ModelMessage]) async {
    self.history = history
    await withCheckedContinuation {
      continuation = $0
      signal.yield(())
    }
  }
  func resume() {
    continuation?.resume()
    continuation = nil
  }
}
private actor FailsOnceCompletion {
  var calls = 0
  func complete() throws {
    calls += 1
    if calls == 1 { throw AgentError.memoryFailure("Synthetic save failure") }
  }
}
private actor CompletionCounter {
  var calls = 0
  func complete() { calls += 1 }
}
