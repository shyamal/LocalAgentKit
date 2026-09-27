import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) -> ModelResponse {
  .toolCall(ToolCall(id: "m", name: name, arguments: ToolArguments(arguments)))
}
private func choice(_ action: String) -> ModelResponse {
  call("choose_next_action", ["action": .string(action)])
}

@Suite struct AgentRuntimeMemoryTests {
  private func runtime(_ model: ScriptedModelProvider, memory: ConversationMemory?) throws
    -> AgentRuntime
  {
    try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([]), memory: memory)
  }

  @Test func withNoMemoryConfiguredNilConversationIsEmpty() async throws {
    let model = ScriptedModelProvider(responses: [choice("finish"), .text("ok")])
    _ = try await runtime(model, memory: nil).run("hi")
    let prompt = await model.requests.first?.messages.last?.content ?? ""
    #expect(!prompt.contains("Recent conversation"))
  }

  @Test func aSuccessfulRunIsRecordedIntoMemory() async throws {
    let memory = ConversationMemory()
    let model = ScriptedModelProvider(responses: [choice("finish"), .text("Two meetings today.")])
    let response = try await runtime(model, memory: memory).run("What meetings do I have?")
    #expect(response.text == "Two meetings today.")
    let history = await memory.history()
    #expect(history.map(\.content) == ["What meetings do I have?", "Two meetings today."])
  }

  @Test func theNextRunWithNilConversationSeesEarlierHistory() async throws {
    let memory = ConversationMemory()
    let model = ScriptedModelProvider(responses: [
      choice("finish"), .text("Two meetings today."), choice("finish"),
      .text("Standup and review."),
    ])
    let runtime = try runtime(model, memory: memory)
    _ = try await runtime.run("What meetings do I have today?")
    _ = try await runtime.run("Which ones exactly?")
    let secondPrompt = await model.requests[2].messages.last?.content ?? ""
    #expect(secondPrompt.contains("What meetings do I have today?"))
    #expect(secondPrompt.contains("Two meetings today."))
  }

  @Test func anExplicitEmptyConversationOverridesMemoryEvenWhenConfigured() async throws {
    let memory = ConversationMemory()
    await memory.recordTurn(goal: "Earlier question?", answer: "Earlier answer.")
    let model = ScriptedModelProvider(responses: [choice("finish"), .text("ok")])
    _ = try await runtime(model, memory: memory).run("New question", conversation: [])
    let prompt = await model.requests.first?.messages.last?.content ?? ""
    #expect(!prompt.contains("Earlier question"))
  }

  @Test func anExplicitConversationOverridesMemoryEntirely() async throws {
    let memory = ConversationMemory()
    await memory.recordTurn(goal: "From memory?", answer: "Memory answer.")
    let override = [ModelMessage(role: .user, content: "From the caller instead")]
    let model = ScriptedModelProvider(responses: [choice("finish"), .text("ok")])
    _ = try await runtime(model, memory: memory).run("New question", conversation: override)
    let prompt = await model.requests.first?.messages.last?.content ?? ""
    #expect(prompt.contains("From the caller instead"))
    #expect(!prompt.contains("From memory?"))
  }

  @Test func aFailedRunIsNotRecorded() async throws {
    let memory = ConversationMemory()
    let refusal = GuardrailRefusal()
    let model = ScriptedModelProvider(responses: [.refused(refusal)])
    let runtime = try runtime(model, memory: memory)
    _ = try? await runtime.run("a risky request")
    #expect(await memory.history().isEmpty)
  }

  @Test func aCancelledRunIsNotRecorded() async throws {
    let memory = ConversationMemory()
    let model = ScriptedModelProvider([.hang])
    let runtime = try runtime(model, memory: memory)
    let run = Task { try await runtime.run("go") }
    try await Task.sleep(for: .milliseconds(50))
    await runtime.cancelCurrentRun()
    _ = try? await run.value
    #expect(await memory.history().isEmpty)
  }
}
