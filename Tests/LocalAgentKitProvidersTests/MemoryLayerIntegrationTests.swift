import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

@Suite struct MemoryLayerIntegrationTests {
  @Test func reopenedCategoriesAndConversationReachOneBudgetedPromptWithoutPersistingTaskFacts()
    async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let knowledgeURL = directory.appendingPathComponent("knowledge.store")
    let conversationURL = directory.appendingPathComponent("conversation.store")
    let id = UUID()
    try await seed(knowledgeURL: knowledgeURL, conversationURL: conversationURL, id: id)
    let knowledge = try SwiftDataMemoryStore(storage: .file(knowledgeURL))
    let checkpoints = try SwiftDataConversationStore(storage: .file(conversationURL))
    let memory = try await ConversationMemory.restore(from: checkpoints, conversationID: id)
    let model = MockModelProvider(
      contextWindowTokens: 2048, handler: { _ in .text("Ready for the meeting") },
      tokenCounter: memoryLayerTokens)
    let taskRead = MockTool(
      name: "read_task", permission: .readOnly, handler: { _ in "task-only evidence 82" })
    let workflow = Workflow(
      name: "prepare", description: "Prepare",
      steps: [
        .tool("task_fact", "Current fact", "read_task"),
        .respond(instruction: "Use the conversation, durable memories and current task fact."),
      ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(
        model: model, memory: knowledge,
        memoryRetrieval: MemoryRetrievalConfiguration(query: .recent)),
      tools: StaticToolSource([taskRead]), planner: StateMachinePlanner(workflow: workflow),
      budgeter: ContextBudgeter(
        configuration: ContextBudgetConfiguration(responseReserveTokens: 100)),
      memory: memory)
    #expect(await runtime.workingMemory().values.isEmpty)
    _ = try await runtime.run("Prepare for Budget review")
    let request = try #require(await model.requests.first)
    let prompt = request.messages.map(\.content).joined(separator: "\n")
    #expect(prompt.contains("Budget review at 10am"))
    #expect(prompt.contains("Use concise bullet points"))
    #expect(prompt.contains("Prepared the previous Budget review"))
    #expect(prompt.contains("task-only evidence 82"))
    #expect(memoryLayerTokens(request) <= 1948)
    #expect(
      await runtime.workingMemory().value(for: "task_fact") == .string("task-only evidence 82"))
    try await memory.checkpoint(to: checkpoints, conversationID: id)
    let reopened = try SwiftDataConversationStore(storage: .file(conversationURL))
    let restored = try await ConversationMemory.restore(from: reopened, conversationID: id)
    let history = await restored.history()
    #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    #expect(history.last?.content == "Ready for the meeting")
    #expect(
      !history.contains {
        $0.content.contains("task-only evidence") || $0.role == .tool || !$0.toolCalls.isEmpty
      })
    #expect(try await knowledge.searchSemantic(text: "concise").count == 1)
    #expect(try await knowledge.searchEpisodic(text: "previous").count == 1)
    #expect(try await knowledge.search(MemoryQuery(text: "task-only")).isEmpty)
  }

  private func seed(knowledgeURL: URL, conversationURL: URL, id: UUID) async throws {
    let knowledge = try SwiftDataMemoryStore(storage: .file(knowledgeURL))
    try await knowledge.save(
      SemanticMemory(kind: .preference, content: "Use concise bullet points"))
    try await knowledge.save(
      EpisodicMemory(
        kind: .action, content: "Prepared the previous Budget review",
        occurredAt: Date(timeIntervalSince1970: 100)))
    let checkpoint = try SwiftDataConversationStore(storage: .file(conversationURL))
    let memory = ConversationMemory()
    await memory.recordTurn(goal: "My meeting?", answer: "Budget review at 10am")
    try await memory.checkpoint(to: checkpoint, conversationID: id)
  }
}

private func memoryLayerTokens(_ request: ModelRequest) -> Int {
  request.messages.reduce(0) { $0 + 4 + $1.content.count / 4 } + request.tools.count * 60
}
