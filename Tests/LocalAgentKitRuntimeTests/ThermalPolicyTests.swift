import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

private func thermalChoice(_ action: String) -> ModelResponse {
  .toolCall(
    ToolCall(
      id: "decision", name: "choose_next_action",
      arguments: ToolArguments(["action": .string(action)])))
}

private actor ThermalEvents {
  var statuses: [ThermalStatus] = []
  var limits: [Int] = []
  func append(_ event: AgentEvent) {
    if case .thermalStateChanged(let status) = event { statuses.append(status) }
    if case .contextUtilization(let context) = event { limits.append(context.limitTokens) }
  }
}

private func thermalRun(
  model: any LocalModelProvider, source: any ThermalStateSource,
  limit: Int? = nil
) async throws -> (AgentResponse, ThermalEvents) {
  let runtime = try AgentRuntime(
    configuration: AgentConfiguration(
      model: model, limits: ExecutionLimits(maxContextTokens: limit)),
    tools: StaticToolSource([]), thermalStateSource: source)
  let captured = ThermalEvents()
  let stream = await runtime.events()
  let consumer = Task { for await event in stream { await captured.append(event) } }
  do {
    let response = try await runtime.run("Say hello")
    await runtime.finishEvents()
    await consumer.value
    return (response, captured)
  } catch {
    await runtime.finishEvents()
    await consumer.value
    throw error
  }
}

private struct HeatingPermissionGate: PermissionGate {
  let source: MockThermalStateSource
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
    source.setState(.critical)
    return .approved
  }
}

@Suite struct ThermalPolicyTests {
  @Test func cancellationTakesPrecedenceAtACheckpoint() async throws {
    let controller = ThermalController(
      source: MockThermalStateSource(.critical), policy: .default, events: EventBus())
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await controller.checkpoint()
    }
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch let error as AgentError { #expect(error == .cancelled) }
  }
  @Test func elevatedStateCapsNeverIncreaseAnExistingLimit() async throws {
    let source = MockThermalStateSource(.serious)
    let model = MockModelProvider(
      contextWindowTokens: 4096,
      handler: { request in request.tools.isEmpty ? .text("Hello") : thermalChoice("finish") },
      tokenCounter: { _ in 100 })
    let (_, captured) = try await thermalRun(model: model, source: source, limit: 1024)
    #expect(await captured.limits == [1024, 1024])
    #expect(await captured.statuses == [ThermalStatus(state: .serious, contextTokenCap: 2048)])
  }

  @Test(arguments: [AgentThermalState.fair, .serious, .unknown])
  func pressureChangesTheActualFittedWindow(_ state: AgentThermalState) async throws {
    let model = MockModelProvider(
      contextWindowTokens: 4096,
      handler: { request in request.tools.isEmpty ? .text("Hello") : thermalChoice("finish") },
      tokenCounter: { _ in 100 })
    let (_, captured) = try await thermalRun(model: model, source: MockThermalStateSource(state))
    let expected = state == .fair ? 3072 : 2048
    #expect(await captured.limits == [expected, expected])
    #expect(await captured.statuses.count == 1)
  }

  @Test func coolingRestoresTheOriginalWindowOnTheNextCall() async throws {
    let source = MockThermalStateSource(.serious)
    let model = MockModelProvider(
      contextWindowTokens: 4096,
      handler: { request in
        source.setState(.nominal)
        return request.tools.isEmpty ? .text("Hello") : thermalChoice("finish")
      }, tokenCounter: { _ in 100 })
    let (_, captured) = try await thermalRun(model: model, source: source)
    #expect(await captured.limits == [2048, 4096])
    #expect(await captured.statuses.map(\.state) == [.serious, .nominal])
  }

  @Test func criticalPressureBlocksBeforePlanningOrProviderCalls() async throws {
    let source = MockThermalStateSource(.critical)
    let model = ScriptedModelProvider([])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([]),
      thermalStateSource: source)
    do {
      _ = try await runtime.run("Run")
      Issue.record("Expected thermal admission failure")
    } catch let error as AgentError { #expect(error == .thermalPressureTooHigh) }
    #expect(await model.requests.isEmpty)
  }

  @Test func criticalPressureDuringTokenCountingBlocksGeneration() async throws {
    let source = MockThermalStateSource()
    let model = MockModelProvider(
      contextWindowTokens: 4096,
      tokenCounter: { _ in
        source.setState(.critical)
        return 100
      })
    do {
      _ = try await thermalRun(model: model, source: source)
      Issue.record("Expected thermal admission failure")
    } catch let error as AgentError { #expect(error == .thermalPressureTooHigh) }
    #expect(await model.requests.isEmpty)
  }

  @Test func heatingDuringTokenCountingRefitsBeforeGeneration() async throws {
    let source = MockThermalStateSource()
    let model = MockModelProvider(
      contextWindowTokens: 4096,
      handler: { request in request.tools.isEmpty ? .text("Hello") : thermalChoice("finish") },
      tokenCounter: { _ in
        source.setState(.serious)
        return 100
      })
    let (_, captured) = try await thermalRun(model: model, source: source)
    let windows = await captured.limits
    #expect(windows == [4096, 2048, 2048])
    #expect(await captured.statuses.map(\.state) == [.nominal, .serious])
  }

  @Test func approvalCannotStartAToolAfterTheDeviceBecomesCritical() async throws {
    let source = MockThermalStateSource()
    let write = MockTool(name: "create_item", permission: .userConfirmation)
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(
        model: ScriptedModelProvider(responses: [thermalChoice("create_item")])),
      tools: StaticToolSource([write]), gate: HeatingPermissionGate(source: source),
      thermalStateSource: source)
    do {
      _ = try await runtime.run("Create an item")
      Issue.record("Expected thermal admission failure")
    } catch let error as AgentError { #expect(error == .thermalPressureTooHigh) }
    #expect(await write.executions.isEmpty)
  }

  @Test func invalidPoliciesAndNetworkSourcesAreRejectedAtConstruction() {
    #expect(throws: AgentError.self) {
      try AgentRuntime(
        configuration: AgentConfiguration(model: MockModelProvider()), tools: StaticToolSource([]),
        thermalPolicy: ThermalPolicy(fairContextTokens: 1000, seriousContextTokens: 2000))
    }
    #expect(throws: AgentError.self) {
      try AgentRuntime(
        configuration: AgentConfiguration(model: MockModelProvider()), tools: StaticToolSource([]),
        thermalPolicy: ThermalPolicy(fairContextTokens: 0))
    }
    #expect(
      throws: AgentError.invalidConfiguration(
        .networkRequiredButForbidden(component: "thermalStateSource"))
    ) {
      try AgentRuntime(
        configuration: AgentConfiguration(model: MockModelProvider()), tools: StaticToolSource([]),
        thermalStateSource: MockThermalStateSource(requiresNetwork: true))
    }
    #expect(throws: Never.self) {
      try AgentRuntime(
        configuration: AgentConfiguration(model: MockModelProvider(), networkPolicy: .allowed),
        tools: StaticToolSource([]),
        thermalStateSource: MockThermalStateSource(requiresNetwork: true))
    }
  }
}
