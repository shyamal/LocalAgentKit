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

@Suite struct BudgetedModelRetrievalTests {
  @Test func retrievedChunksAreMergedIntoTheFittedRequest() async throws {
    let model = MockModelProvider(handler: { _ in .text("ok") })
    let budgeted = BudgetedModel(
      base: model, budgeter: ContextBudgeter(), limits: .default,
      clock: RunClock(budget: .seconds(30)), events: EventBus(),
      retrievedChunks: ["a relevant passage"])
    _ = try await budgeted.generate(
      request: ModelRequest(messages: [ModelMessage(role: .user, content: "find it")]))
    let seen = await model.requests.first
    let documentsMessage = seen?.messages.first { $0.content.contains("Relevant documents:") }
    #expect(documentsMessage?.content.contains("a relevant passage") == true)
  }

  @Test func noRetrievedChunksMeansNoDocumentsSection() async throws {
    let model = MockModelProvider(handler: { _ in .text("ok") })
    let budgeted = BudgetedModel(
      base: model, budgeter: ContextBudgeter(), limits: .default,
      clock: RunClock(budget: .seconds(30)), events: EventBus())
    _ = try await budgeted.generate(
      request: ModelRequest(messages: [ModelMessage(role: .user, content: "hi")]))
    let seen = await model.requests.first
    #expect(!(seen?.messages.contains { $0.content.contains("Relevant documents:") } ?? true))
  }
}

@Suite struct AgentRuntimeRetrievalTests {
  private func runtime(
    _ model: ScriptedModelProvider, embedding: (any EmbeddingProvider)? = nil,
    vectorStore: (any VectorStore)? = nil
  ) throws -> AgentRuntime {
    try AgentRuntime(
      configuration: AgentConfiguration(
        model: model, embedding: embedding, vectorStore: vectorStore),
      tools: StaticToolSource([]))
  }

  @Test func withNoRagConfiguredNoRetrievalHappens() async throws {
    let model = ScriptedModelProvider(responses: [choice("finish"), .text("ok")])
    let runtime = try runtime(model)
    #expect(try await runtime.run("find my notes about the budget").text == "ok")
  }

  @Test func withRagConfiguredTheGoalIsRetrievedOnceAndInjected() async throws {
    let embedder = MockEmbeddingProvider()
    let store = MockVectorStore()
    try await store.insert([
      EmbeddedDocument(
        text: "the Q3 budget review is Tuesday",
        vector: try await embedder.embed(text: "budget review Tuesday"))
    ])
    let model = ScriptedModelProvider(responses: [choice("finish"), .text("ok")])
    let runtime = try runtime(model, embedding: embedder, vectorStore: store)
    _ = try await runtime.run("what does the budget review say")
    let prompt = await model.requests.first {
      $0.messages.contains { $0.content.contains("Relevant documents:") }
    }
    #expect(prompt != nil)
  }

  @Test func aRetrievalFailureIsBestEffortAndDoesNotFailTheRun() async throws {
    struct FailingEmbedding: EmbeddingProvider {
      let requiresNetwork = false
      func embed(text: String) async throws -> [Float] { throw AgentError.retrievalFailure("boom") }
    }
    let model = ScriptedModelProvider(responses: [choice("finish"), .text("ok")])
    let runtime = try runtime(model, embedding: FailingEmbedding(), vectorStore: MockVectorStore())
    #expect(try await runtime.run("anything").text == "ok")
  }

  @Test func onlyOneOfEmbeddingOrVectorStoreConfiguredMeansNoRetrieval() async throws {
    let model = ScriptedModelProvider(responses: [choice("finish"), .text("ok")])
    let runtime = try runtime(model, embedding: MockEmbeddingProvider(), vectorStore: nil)
    #expect(try await runtime.run("anything").text == "ok")
  }
}
