import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

private func finishChoice() -> ModelResponse {
  .toolCall(
    ToolCall(
      id: "finish", name: "choose_next_action",
      arguments: ToolArguments(["action": .string("finish")])))
}

/// Intentionally ignores cancellation in the first request, then calls the stale callback
/// from the second request's live task. Only channel closure can reject that fragment.
private actor LateStreamingModel: LocalModelProvider {
  private var saved: (@Sendable (String) async -> Void)?
  private var pending: CheckedContinuation<ModelResponse, Never>?
  private var started = false

  func generate(request: ModelRequest) async throws -> ModelResponse { finishChoice() }

  func generate(
    request: ModelRequest, onToken: @escaping @Sendable (String) async -> Void
  ) async throws -> ModelResponse {
    if !started {
      started = true
      saved = onToken
      return await withCheckedContinuation { pending = $0 }
    }
    await saved?("STALE")
    saved = nil
    pending?.resume(returning: .text("Old"))
    pending = nil
    await onToken("Fresh")
    return .text("Fresh")
  }
}

@Suite struct ResponseStreamingTests {
  @Test func onlyFinalAnswersEmitFragmentsInOrderBeforeCompletion() async throws {
    let model = ScriptedModelProvider([
      .stream(["PRIVATE_DECISION"], then: finishChoice()),
      .stream(["", "Hel", "lo"], then: .text("Hello")),
    ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([]))
    let stream = await runtime.events()
    let response = try await runtime.run("Say hello")
    await runtime.finishEvents()
    var tokens: [String] = []
    var seenCompletion = false
    for await event in stream {
      if case .responseToken(let token) = event {
        #expect(!seenCompletion)
        tokens.append(token)
      }
      if case .completed = event { seenCompletion = true }
    }
    #expect(seenCompletion)
    #expect(tokens == ["Hel", "lo"])
    #expect(response.text == tokens.joined())
    #expect(await model.requests.map(\.purpose) == [.decision, .answer])
  }

  @Test func providersWithoutStreamingKeepWorkingWithoutFakeFragments() async throws {
    let model = MockModelProvider { request in
      request.tools.isEmpty ? .text("Hello") : finishChoice()
    }
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([]))
    let stream = await runtime.events()
    #expect(try await runtime.run("Say hello").text == "Hello")
    await runtime.finishEvents()
    for await event in stream {
      if case .responseToken = event { Issue.record("Non-streaming response emitted a token") }
    }
  }

  @Test func declaringToolsDisablesStreamingEvenWithAnswerPurpose() async throws {
    let bus = EventBus()
    let stream = await bus.subscribe()
    let base = ScriptedModelProvider([.stream(["PRIVATE_ARGUMENTS"], then: finishChoice())])
    let model = BudgetedModel(
      base: base, budgeter: ContextBudgeter(), limits: .default,
      clock: RunClock(budget: .seconds(1)), events: bus)
    _ = try await model.generate(
      request: ModelRequest(
        messages: [ModelMessage(role: .user, content: "Choose")],
        tools: [ToolDescriptor(MockTool())], purpose: .answer))
    await bus.finish()
    for await event in stream {
      if case .responseToken = event { Issue.record("Tool-bearing request leaked fragments") }
    }
  }

  @Test func lateCallbacksCannotContaminateTheNextRun() async throws {
    let model = LateStreamingModel()
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(
        model: model, limits: ExecutionLimits(maxModelCallDuration: .milliseconds(30))),
      tools: StaticToolSource([]))
    let stream = await runtime.events()
    do {
      _ = try await runtime.run("First")
      Issue.record("Expected a timeout")
    } catch let error as AgentError { #expect(error == .executionTimeout(.modelCall)) }
    #expect(try await runtime.run("Second").text == "Fresh")
    await runtime.finishEvents()
    var tokens: [String] = []
    for await event in stream {
      if case .responseToken(let token) = event { tokens.append(token) }
    }
    #expect(tokens == ["Fresh"])
  }
}
