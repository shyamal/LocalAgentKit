import Foundation
import FoundationModels
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Synchronization
import Testing

@testable import LocalAgentKitProviders

@available(macOS 27, iOS 27, *)
private final class FixtureConfiguration: Sendable, Hashable {
  let id = UUID()
  let initializations = Mutex(0)
  static func == (lhs: FixtureConfiguration, rhs: FixtureConfiguration) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@available(macOS 27, iOS 27, *)
private actor FixtureBackend {
  enum Step: Sendable {
    case text([String])
    case tool(String, String)
    case refusal
    case overflow
    case hang
    case revision
  }
  var steps: [Step]
  var requests: [LanguageModelExecutorGenerationRequest] = []
  init(_ steps: [Step]) { self.steps = steps }

  func respond(
    _ request: LanguageModelExecutorGenerationRequest,
    channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    requests.append(request)
    guard !steps.isEmpty else { throw AgentError.modelUnavailable(reason: "Fixture exhausted") }
    switch steps.removeFirst() {
    case .text(let fragments):
      for text in fragments {
        try Task.checkCancellation()
        await channel.send(.response(action: .appendText(text, tokenCount: 1)))
      }
    case .tool(let name, let arguments):
      await channel.send(
        .toolCalls(
          action: .toolCall(
            id: "fixture-call", name: name, action: .appendArguments(arguments, tokenCount: 1))))
    case .refusal:
      throw LanguageModelError.refusal(
        .init(explanation: "Declined", debugDescription: "Fixture refusal"))
    case .overflow:
      throw LanguageModelError.contextSizeExceeded(
        .init(contextSize: 100, tokenCount: 200, debugDescription: "Fixture overflow"))
    case .hang:
      while true { try await Task.sleep(for: .seconds(3600)) }
    case .revision:
      let id = request.id.uuidString
      await channel.send(
        .response(entryID: id, action: .appendText("Old", segmentID: "s", tokenCount: 1)))
      await channel.send(
        .response(entryID: id, action: .replaceTextSegment("New", segmentID: "s", tokenCount: 1)))
    }
  }
}

@available(macOS 27, iOS 27, *)
private struct FixtureLanguageModel: LanguageModel {
  let backend: FixtureBackend
  let executorConfiguration = FixtureConfiguration()
  var supportsTools = true
  var capabilities: LanguageModelCapabilities {
    LanguageModelCapabilities(supportsTools ? [.toolCalling, .guidedGeneration] : [])
  }

  struct Executor: LanguageModelExecutor {
    typealias Model = FixtureLanguageModel
    typealias Configuration = FixtureConfiguration
    init(configuration: Configuration) throws { configuration.initializations.withLock { $0 += 1 } }
    nonisolated(nonsending) func respond(
      to request: LanguageModelExecutorGenerationRequest, model: Model,
      streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
      try await model.backend.respond(request, channel: channel)
    }
  }
}

private actor AdapterFragments {
  var text = ""
  func append(_ text: String) { self.text += text }
}

private actor CounterEntries {
  var entries: [Transcript.Entry] = []
  func record(_ entries: [Transcript.Entry]) { self.entries = entries }
}

private struct DenyAdapterTool: PermissionGate {
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision { .denied }
}

private var customModelsAvailable: Bool {
  if #available(macOS 27, iOS 27, *) { true } else { false }
}

@Suite(.enabled(if: customModelsAvailable))
struct LanguageModelProviderTests {
  private let request = ModelRequest(messages: [ModelMessage(role: .user, content: "Hello")])

  @Test func aNativeCustomPlanCannotBypassRuntimePermission() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let backend = FixtureBackend([
      .tool("choose_next_action", "{\"action\":\"create_item\"}"),
      .tool("provide_create_item_arguments", "{\"name\":\"Ada\"}"),
    ])
    let tool = MockTool(
      name: "create_item",
      schema: ToolSchema(
        parameters: ["name": ToolParameter(.string, description: "Name")], required: ["name"]),
      permission: .userConfirmation)
    let provider = try LanguageModelProvider(
      model: FixtureLanguageModel(backend: backend), requiresNetwork: false)
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: provider), tools: StaticToolSource([tool]),
      gate: DenyAdapterTool())
    await #expect(throws: AgentError.permissionDenied(tool: "create_item")) {
      try await runtime.run("Create an item named Ada")
    }
    #expect(await tool.executions.isEmpty)
    #expect(await backend.requests.count == 2)
  }

  @Test func cancellationAndDeadlinesUseTheExistingRuntimeBoundaries() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let backend = FixtureBackend([.tool("choose_next_action", "{\"action\":\"finish\"}"), .hang])
    let provider = try LanguageModelProvider(
      model: FixtureLanguageModel(backend: backend), requiresNetwork: false)
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(
        model: provider, limits: ExecutionLimits(maxModelCallDuration: .milliseconds(100))),
      tools: StaticToolSource([]))
    await #expect(throws: AgentError.executionTimeout(.modelCall)) {
      try await runtime.run("Answer")
    }
    let tokens = AdapterFragments()
    let streaming = try LanguageModelProvider(
      model: FixtureLanguageModel(backend: FixtureBackend([.text(["One", " two"])])),
      requiresNetwork: false, enableStreaming: true)
    let cancelled = Task {
      try await streaming.generate(request: request) { fragment in
        await tokens.append(fragment)
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    await #expect(throws: AgentError.cancelled) { try await cancelled.value }
  }

  @Test func aCustomExecutorRunsWithoutTheSystemModelOrAssets() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let backend = FixtureBackend([.text(["Hello", " world"])])
    let model = FixtureLanguageModel(backend: backend)
    let provider = try LanguageModelProvider(
      model: model, requiresNetwork: false, contextWindowTokens: 2048)
    #expect(model.executorConfiguration.initializations.withLock { $0 } == 0)
    #expect(provider.contextWindowTokens == 2048)
    #expect(await provider.tokenCount(for: request) == nil)
    #expect(try await provider.generate(request: request) == .text("Hello world"))
    #expect(await backend.requests.count == 1)
  }

  @Test func customStreamingUsesTheSameAppendOnlyBridge() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let backend = FixtureBackend([.text(["Hel", "lo"])])
    let provider = try LanguageModelProvider(
      model: FixtureLanguageModel(backend: backend), requiresNetwork: false, enableStreaming: true)
    let fragments = AdapterFragments()
    let response = try await provider.generate(request: request) { await fragments.append($0) }
    #expect(response == .text("Hello"))
    #expect(await fragments.text == "Hello")
  }

  @Test func replacementBackendsDefaultToFinalTextWithoutPartialFragments() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let provider = try LanguageModelProvider(
      model: FixtureLanguageModel(backend: FixtureBackend([.revision])), requiresNetwork: false)
    let tokens = AdapterFragments()
    let response = try await provider.generate(request: request) { await tokens.append($0) }
    #expect(response == .text("New"))
    #expect(await tokens.text.isEmpty)
  }

  @Test func aTextOnlyModelCanAnswerWithoutAdvertisingTools() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let model = FixtureLanguageModel(
      backend: FixtureBackend([.text(["Plain answer"])]), supportsTools: false)
    let provider = try LanguageModelProvider(model: model, requiresNetwork: false)
    #expect(try await provider.generate(request: request) == .text("Plain answer"))
  }

  @Test func toolCallsAreHandedBackWithoutExecutingTheAgentTool() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let backend = FixtureBackend([.tool("create_item", "{\"name\":\"Ada\"}")])
    let tool = MockTool(
      name: "create_item",
      schema: ToolSchema(
        parameters: ["name": ToolParameter(.string, description: "Name")], required: ["name"]),
      permission: .userConfirmation)
    let provider = try LanguageModelProvider(
      model: FixtureLanguageModel(backend: backend), requiresNetwork: false)
    let response = try await provider.generate(
      request: ModelRequest(messages: request.messages, tools: [ToolDescriptor(tool)]))
    guard case .toolCall(let call) = response else {
      Issue.record("Expected a handed-back tool call, got \(response)")
      return
    }
    #expect(call.name == "create_item")
    #expect(call.arguments.string("name") == "Ada")
    #expect(await tool.executions.isEmpty)
  }

  @Test func renderedTokenCounterReceivesToolDefinitions() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let captured = CounterEntries()
    let provider = try LanguageModelProvider(
      model: FixtureLanguageModel(backend: FixtureBackend([])), requiresNetwork: false,
      tokenCounter: { entries in
        await captured.record(entries)
        return 42
      })
    let tool = ToolDescriptor(MockTool(name: "read_item"))
    #expect(
      await provider.tokenCount(for: ModelRequest(messages: request.messages, tools: [tool])) == 42)
    let entries = await captured.entries
    guard case .instructions(let instructions) = entries.first else {
      Issue.record("Expected instructions carrying tool definitions")
      return
    }
    #expect(instructions.toolDefinitions.map(\.name) == ["read_item"])
  }

  @Test func networkRequirementIsExplicitAndRejectedOffline() throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let provider = try LanguageModelProvider(
      model: FixtureLanguageModel(backend: FixtureBackend([])), requiresNetwork: true)
    #expect(
      throws: AgentError.invalidConfiguration(.networkRequiredButForbidden(component: "model"))
    ) {
      try AgentRuntime(
        configuration: AgentConfiguration(model: provider), tools: StaticToolSource([]))
    }
    #expect(throws: Never.self) {
      try AgentRuntime(
        configuration: AgentConfiguration(model: provider, networkPolicy: .allowed),
        tools: StaticToolSource([]))
    }
  }

  @Test func invalidWindowAndMissingToolCapabilityAreTyped() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let backend = FixtureBackend([])
    let model = FixtureLanguageModel(backend: backend, supportsTools: false)
    #expect(throws: AgentError.self) {
      try LanguageModelProvider(model: model, requiresNetwork: false, contextWindowTokens: 0)
    }
    let provider = try LanguageModelProvider(model: model, requiresNetwork: false)
    do {
      _ = try await provider.generate(
        request: ModelRequest(messages: request.messages, tools: [ToolDescriptor(MockTool())]))
      Issue.record("Expected a capability error")
    } catch let error as AgentError {
      guard case .modelUnavailable = error else { throw error }
    }
    #expect(await backend.requests.isEmpty)
  }

  @Test func nativeRefusalIsTerminalAndOverflowIsTyped() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let backend = FixtureBackend([.refusal, .overflow])
    let provider = try LanguageModelProvider(
      model: FixtureLanguageModel(backend: backend), requiresNetwork: false)
    do {
      _ = try await provider.generate(request: request)
      Issue.record("Expected refusal")
    } catch let error as AgentError {
      #expect(error == .guardrailRefusal(GuardrailRefusal(explanation: "Declined")))
    }
    #expect(await backend.requests.count == 1)
    await #expect(throws: AgentError.contextLimitExceeded) {
      try await provider.generate(request: request)
    }
    #expect(await backend.requests.count == 2)
  }

  @Test func providerCopiesUseTheSameAppBackend() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let backend = FixtureBackend([.text(["One"]), .text(["Two"])])
    let provider = try LanguageModelProvider(
      model: FixtureLanguageModel(backend: backend), requiresNetwork: false)
    let copy = provider
    async let first = provider.generate(request: request)
    async let second = copy.generate(request: request)
    let responses = try await [first, second]
    #expect(Set(responses) == Set([.text("One"), .text("Two")]))
    #expect(await backend.requests.count == 2)
  }
}
