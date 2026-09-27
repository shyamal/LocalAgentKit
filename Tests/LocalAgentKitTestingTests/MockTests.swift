import Foundation
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitTesting

private let request = ModelRequest(messages: [ModelMessage(role: .user, content: "hi")])

@Suite struct ScriptedModelProviderTests {
  @Test func playsStepsInOrderAndRecordsRequests() async throws {
    let call = ToolCall(id: "1", name: "echo")
    let model = ScriptedModelProvider(responses: [.toolCall(call), .text("done")])
    #expect(try await model.generate(request: request) == .toolCall(call))
    #expect(try await model.generate(request: request) == .text("done"))
    #expect(await model.requests.count == 2)
    #expect(await model.remainingSteps == 0)
  }

  @Test func exhaustedScriptFailsLoudly() async {
    let model = ScriptedModelProvider([])
    await #expect(throws: AgentError.self) { try await model.generate(request: request) }
  }

  @Test func failStepThrowsItsError() async {
    let model = ScriptedModelProvider([.fail(.contextLimitExceeded)])
    await #expect(throws: AgentError.contextLimitExceeded) {
      try await model.generate(request: request)
    }
  }

  @Test func refusalIsAResponseNotAnError() async throws {
    let refusal = GuardrailRefusal(explanation: "no")
    let model = ScriptedModelProvider(responses: [.refused(refusal)])
    #expect(try await model.generate(request: request) == .refused(refusal))
  }

  @Test func delayStepAnswersAfterWaiting() async throws {
    let model = ScriptedModelProvider([.delay(.milliseconds(20), then: .text("late"))])
    #expect(try await model.generate(request: request) == .text("late"))
  }

  @Test func hangEndsOnCancellationAsTypedError() async {
    let model = ScriptedModelProvider([.hang])
    let task = Task { try await model.generate(request: request) }
    try? await Task.sleep(for: .milliseconds(20))
    task.cancel()
    await #expect(throws: AgentError.cancelled) { try await task.value }
  }

  @Test func reportsNetworkAndWindow() {
    let model = ScriptedModelProvider([], requiresNetwork: true, contextWindowTokens: 4096)
    #expect(model.requiresNetwork)
    #expect(model.contextWindowTokens == 4096)
  }
}

@Suite struct MockModelProviderTests {
  @Test func defaultAnswersAndRecords() async throws {
    let model = MockModelProvider()
    #expect(try await model.generate(request: request) == .text("mock"))
    #expect(await model.requests == [request])
  }

  @Test func handlerSeesTheRequest() async throws {
    let model = MockModelProvider { req in .text("\(req.messages.count)") }
    #expect(try await model.generate(request: request) == .text("1"))
  }

  @Test func cancellationBecomesTypedError() async {
    let model = MockModelProvider()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await model.generate(request: request)
    }
    await #expect(throws: AgentError.cancelled) { try await task.value }
  }
}

@Suite struct MockToolTests {
  @Test func recordsExecutions() async throws {
    let tool = MockTool(handler: { args in args.string("q") ?? "" })
    let result = try await tool.execute(arguments: ToolArguments(["q": "x"]))
    #expect(result.text == "x")
    #expect(await tool.executions == [ToolArguments(["q": "x"])])
  }

  @Test func neverRunMeansEmpty() async {
    let tool = MockTool(permission: .destructive)
    #expect(await tool.executions.isEmpty)
    #expect(tool.permission == .destructive)
  }
}

@Suite struct MockStoreTests {
  @Test func memorySaveSearchDelete() async throws {
    let store = MockMemoryStore()
    let memory = Memory(content: "Prefers Tuesday meetings")
    try await store.save(memory)
    try await store.save(memory)
    #expect(try await store.search(MemoryQuery(text: "tuesday")).count == 1)
    #expect(try await store.search(MemoryQuery(text: "friday")).isEmpty)
    try await store.delete(id: memory.id)
    #expect(await store.all.isEmpty)
  }

  @Test func vectorSearchRanksBySimilarity() async throws {
    let embedder = MockEmbeddingProvider()
    let store = MockVectorStore()
    let texts = ["budget meeting", "zebra zoo", "meeting budget notes"]
    var documents: [EmbeddedDocument] = []
    for text in texts {
      documents.append(EmbeddedDocument(text: text, vector: try await embedder.embed(text: text)))
    }
    try await store.insert(documents)
    let hits = try await store.search(vector: try await embedder.embed(text: "budget"), limit: 2)
    #expect(hits.count == 2)
    #expect(!hits.map(\.document.text).contains("zebra zoo"))
    #expect(await store.stored.count == 3)
  }

  @Test func embeddingIsDeterministic() async throws {
    let embedder = MockEmbeddingProvider()
    #expect(try await embedder.embed(text: "Abc") == embedder.embed(text: "cba"))
  }
}
