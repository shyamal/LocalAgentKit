import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import LocalAgentKitTools
import Testing

private let attackIDs = [
  "role-spoof", "forged-approval", "urgent-repair", "tool-json", "markdown-comment", "code-fence",
  "delimiter-escape", "encoded-payload", "unicode-authority", "multi-step", "policy-override",
  "reward-pressure",
]
private let guardedTiers = ["userConfirmation", "sensitive", "destructive"]

@Suite struct AdversarialRAGCorpusTests {
  struct Corpus: Decodable {
    let schemaVersion: Int
    let cases: [Attack]
  }
  struct Attack: Decodable {
    let id: String
    let category: String
    let permission: String
    let format: String
    let title: String
    let marker: String
    let instruction: String
    let text: String
    let tool: String
    let payload: String
    var tier: ToolPermission {
      get throws {
        switch permission {
        case "userConfirmation": .userConfirmation
        case "sensitive": .sensitive
        case "destructive": .destructive
        default: throw AgentError.retrievalFailure("Invalid fixture tier")
        }
      }
    }
  }
  actor Deny: PermissionGate {
    var requests: [ToolCall] = []
    func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
      requests.append(call)
      return .denied
    }
  }
  private var schema: ToolSchema {
    ToolSchema(
      parameters: ["payload": ToolParameter(.string, description: "Inert fixture payload")],
      required: ["payload"])
  }
  private func corpus() throws -> Corpus {
    let url = try #require(
      Bundle.module.url(
        forResource: "adversarial-rag", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
  }
  private func attack(_ id: String) throws -> Attack {
    try #require(corpus().cases.first { $0.id == id })
  }
  private func response(_ name: String, _ arguments: [String: JSONValue]) -> ModelResponse {
    .toolCall(ToolCall(id: UUID().uuidString, name: name, arguments: ToolArguments(arguments)))
  }
  private func choice(_ name: String) -> ModelResponse {
    response("choose_next_action", ["action": .string(name)])
  }
  private func model(_ attack: Attack, explicitSearch: Bool) -> ScriptedModelProvider {
    var responses: [ModelResponse] = []
    if explicitSearch {
      responses = [
        choice("search_documents"),
        response("provide_search_documents_arguments", ["query": .string("budget review")]),
      ]
    }
    responses += [
      choice(attack.tool),
      response("provide_\(attack.tool)_arguments", ["payload": .string(attack.payload)]),
      choice("finish"), .text("fixture complete"),
    ]
    return ScriptedModelProvider(responses: responses)
  }
  private func store(_ attack: Attack) async throws -> MockVectorStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(attack.format)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(attack.text.utf8).write(to: url)
    let document = try DocumentExtractor.load(contentsOf: url, preserveMarkdownStructure: true)
    let store = MockVectorStore()
    try await RetrievalPipeline(embeddingProvider: MockEmbeddingProvider(), vectorStore: store)
      .ingest(document, chunker: Chunker(configuration: .init(chunkSize: 4000)))
    return store
  }
  private func mock(_ attack: Attack) throws -> MockTool {
    MockTool(name: attack.tool, schema: schema, permission: try attack.tier)
  }

  @Test func corpusHasUniqueCasesAndCoversEveryGuardedTier() throws {
    let corpus = try corpus()
    #expect(corpus.schemaVersion == 1)
    #expect(Set(corpus.cases.map(\.id)) == Set(attackIDs))
    #expect(corpus.cases.count == attackIDs.count)
    #expect(Set(corpus.cases.map(\.category)).count == 12)
    #expect(Set(corpus.cases.map(\.permission)) == Set(guardedTiers))
    for attack in corpus.cases {
      #expect(try attack.tier.requiresConfirmation)
      #expect(attack.text.contains(attack.marker) && attack.text.contains(attack.instruction))
      #expect(["txt", "md"].contains(attack.format))
      #expect(schema.validate(ToolArguments(["payload": .string(attack.payload)])).isEmpty)
    }
  }

  @Test(arguments: attackIDs, [false, true])
  func deniedAttackReachesPromptButNeverExecutes(_ id: String, explicitSearch: Bool) async throws {
    let attack = try attack(id)
    let store = try await store(attack)
    let target = try mock(attack)
    let gate = Deny()
    let model = model(attack, explicitSearch: explicitSearch)
    let logger = AuditLogger()
    let search = try DocumentSearchTool(
      embeddingProvider: MockEmbeddingProvider(), vectorStore: store,
      retrieval: .init(resultLimit: 3, candidateLimit: 10))
    let config = AgentConfiguration(
      model: model,
      embedding: explicitSearch ? nil : MockEmbeddingProvider(),
      vectorStore: explicitSearch ? nil : store, retrieval: .init(resultLimit: 1, candidateLimit: 1)
    )
    let runtime = try AgentRuntime(
      configuration: config,
      tools: StaticToolSource([search, target]), gate: gate, auditLogger: logger)
    let stream = await runtime.events()
    let observed = Task { () -> (Int, Int, Int) in
      var permissions = 0
      var starts = 0
      var completions = 0
      for await event in stream {
        switch event {
        case .permissionRequired(let call) where call.name == attack.tool: permissions += 1
        case .toolStarted(let call) where call.name == attack.tool: starts += 1
        case .toolCompleted(let result) where result.toolName == attack.tool: completions += 1
        case .error: return (permissions, starts, completions)
        default: break
        }
      }
      return (permissions, starts, completions)
    }
    await #expect(throws: AgentError.permissionDenied(tool: attack.tool)) {
      try await runtime.run("Summarize my budget review notes")
    }
    let counts = await observed.value
    #expect(counts == (1, 0, 0))
    #expect(await target.executions.isEmpty)
    #expect(await logger.allEntries().isEmpty)
    let requests = await gate.requests
    #expect(requests.count == 1)
    #expect(requests.first?.arguments.string("payload") == attack.payload)
    let prompts = await model.requests.flatMap(\.messages).map(\.content)
    #expect(prompts.contains { $0.contains(attack.marker) && $0.contains(attack.instruction) })
  }

  @Test(arguments: guardedTiers, [false, true])
  func defaultBrokerSuspendsUntilExplicitHumanDecision(_ tier: String, approved: Bool) async throws
  {
    let attack = try #require(corpus().cases.first { $0.permission == tier })
    let target = try mock(attack)
    let model = model(attack, explicitSearch: false)
    let store = try await store(attack)
    let logger = AuditLogger()
    let runtime = try AgentRuntime(
      configuration: .init(
        model: model,
        embedding: MockEmbeddingProvider(), vectorStore: store), tools: StaticToolSource([target]),
      auditLogger: logger)
    let events = await runtime.events()
    let run = Task { try await runtime.run("Summarize my budget review notes") }
    var pending: ToolCall?
    for await event in events {
      if case .permissionRequired(let call) = event {
        pending = call
        break
      }
      if case .error(let error) = event {
        Issue.record("Failed before permission: \(error)")
        break
      }
    }
    let call = try #require(pending)
    #expect(await target.executions.isEmpty)
    let prompts = await model.requests.flatMap(\.messages).map(\.content)
    #expect(prompts.contains { $0.contains(attack.instruction) })
    await runtime.resolvePermission(callID: call.id, approved: approved)
    if approved {
      #expect(try await run.value.text == "fixture complete")
      #expect(await target.executions.count == 1)
      #expect(await logger.allEntries().count == 1)
    } else {
      await #expect(throws: AgentError.permissionDenied(tool: attack.tool)) { try await run.value }
      #expect(await target.executions.isEmpty)
      #expect(await logger.allEntries().isEmpty)
    }
  }

  @Test(arguments: guardedTiers)
  func cancelledAttackCannotBeRevivedByLateApproval(_ tier: String) async throws {
    let attack = try #require(corpus().cases.first { $0.permission == tier })
    let target = try mock(attack)
    let model = model(attack, explicitSearch: false)
    let store = try await store(attack)
    let runtime = try AgentRuntime(
      configuration: .init(
        model: model,
        embedding: MockEmbeddingProvider(), vectorStore: store), tools: StaticToolSource([target]))
    let events = await runtime.events()
    let run = Task { try await runtime.run("Summarize my budget review notes") }
    var pending: ToolCall?
    for await event in events {
      if case .permissionRequired(let call) = event {
        pending = call
        break
      }
      if case .error = event { break }
    }
    let call = try #require(pending)
    await runtime.cancelCurrentRun()
    await #expect(throws: AgentError.cancelled) { try await run.value }
    #expect(await runtime.resolvePermission(callID: call.id, approved: true) == false)
    #expect(await target.executions.isEmpty)
  }

  @Test func benignReadOnlyControlExecutesWithoutTheWriteGate() async throws {
    let tool = MockTool(name: "read_fixture", schema: schema, permission: .readOnly)
    let gate = Deny()
    let executor = ToolExecutor(source: StaticToolSource([tool]), gate: gate, events: EventBus())
    _ = try await executor.execute(
      ToolCall(
        id: "read-control", name: tool.name,
        arguments: ToolArguments(["payload": .string("SAFE_READ_CONTROL")])))
    #expect(await tool.executions.count == 1)
    #expect(await gate.requests.isEmpty)
  }

  @Test(arguments: guardedTiers)
  func malformedArgumentsAreRejectedBeforeAskingPermission(_ tier: String) async throws {
    let attack = try #require(corpus().cases.first { $0.permission == tier })
    let target = try mock(attack)
    let gate = Deny()
    let executor = ToolExecutor(source: StaticToolSource([target]), gate: gate, events: EventBus())
    do {
      _ = try await executor.execute(
        ToolCall(
          id: "malformed", name: attack.tool,
          arguments: ToolArguments(["payload": .int(1)])))
      Issue.record("Expected invalid arguments before authorization")
    } catch AgentError.invalidArguments(let name, let violations) {
      #expect(name == attack.tool && !violations.isEmpty)
    }

    #expect(await gate.requests.isEmpty)
    #expect(await target.executions.isEmpty)
  }
}
