import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

private func traceChoice(_ action: String) -> ModelResponse {
  .toolCall(
    ToolCall(
      id: "decision", name: "choose_next_action",
      arguments: ToolArguments(["action": .string(action)])))
}

private func expectBalanced(_ sink: MockRuntimeInstrumentation, runs: Int = 1) {
  let events = sink.events
  #expect(Set(events.map(\.runID)).count == runs)
  let groups = Dictionary(grouping: events, by: \.intervalID)
  for boundaries in groups.values {
    #expect(boundaries.map(\.phase) == [.began, .ended])
    #expect(Set(boundaries.map(\.operation)).count == 1)
    #expect(Set(boundaries.map(\.runID)).count == 1)
  }
  for run in Set(events.map(\.runID)) {
    let scoped = events.filter { $0.runID == run }
    #expect(scoped.first?.operation == .run)
    #expect(scoped.last?.operation == .run)
    #expect(scoped.first?.phase == .began)
    #expect(scoped.last?.phase == .ended)
  }
}

@Suite struct RuntimeInstrumentationTests {
  @Test func networkDiagnosticsAreRejectedUnderTheOfflinePolicy() throws {
    let sink = MockRuntimeInstrumentation(requiresNetwork: true)
    #expect(
      throws: AgentError.invalidConfiguration(
        .networkRequiredButForbidden(component: "instrumentation"))
    ) {
      try AgentRuntime(
        configuration: AgentConfiguration(model: MockModelProvider()),
        tools: StaticToolSource([]), instrumentation: sink)
    }
    #expect(throws: Never.self) {
      try AgentRuntime(
        configuration: AgentConfiguration(model: MockModelProvider(), networkPolicy: .allowed),
        tools: StaticToolSource([]), instrumentation: sink)
    }
    #expect(sink.events.isEmpty)
  }
  @Test func successRecordsCorrelatedModelPlanningAndToolIntervals() async throws {
    let sink = MockRuntimeInstrumentation()
    let tool = MockTool(name: "read_item", handler: { _ in "PRIVATE_RESULT" })
    let model = ScriptedModelProvider(responses: [
      traceChoice("read_item"), traceChoice("finish"), .text("PRIVATE_ANSWER"),
    ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([tool]),
      instrumentation: sink)
    _ = try await runtime.run("PRIVATE_GOAL")
    expectBalanced(sink)
    let starts = sink.events.filter { $0.phase == .began }
    #expect(starts.filter { $0.operation == .modelCall }.count == 3)
    #expect(starts.filter { $0.operation == .toolCall }.count == 1)
    #expect(starts.filter { $0.operation == .planning }.count == 1)
    // The diagnostic value type has no slots for any of these payloads.
    #expect(!String(describing: sink.events).contains("PRIVATE_"))
  }

  @Test(arguments: ["refusal", "timeout", "context", "tool_failure"])
  func failuresStillCloseEveryInterval(_ failure: String) async throws {
    let sink = MockRuntimeInstrumentation()
    let tool = MockTool(
      name: "read_item",
      handler: { _ in
        throw AgentError.toolFailed(tool: "read_item", message: "PRIVATE_FAILURE")
      })
    let model: ScriptedModelProvider
    var limits = ExecutionLimits()
    switch failure {
    case "refusal": model = ScriptedModelProvider(responses: [.refused(GuardrailRefusal())])
    case "timeout":
      model = ScriptedModelProvider([.hang])
      limits.maxModelCallDuration = .milliseconds(20)
    case "context":
      model = ScriptedModelProvider([])
      limits.maxContextTokens = 1
    default:
      model = ScriptedModelProvider(responses: [traceChoice("read_item"), traceChoice("read_item")])
    }
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model, limits: limits),
      tools: StaticToolSource([tool]), instrumentation: sink)
    do {
      _ = try await runtime.run("PRIVATE_GOAL")
      Issue.record("Expected the run to fail")
    } catch is AgentError {
      expectBalanced(sink)
      #expect(!String(describing: sink.events).contains("PRIVATE_"))
    }
  }

  @Test func cancelledPermissionWaitClosesPermissionAndToolSpans() async throws {
    let sink = MockRuntimeInstrumentation()
    let tool = MockTool(name: "create_item", permission: .userConfirmation)
    let model = ScriptedModelProvider(responses: [traceChoice("create_item")])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([tool]),
      instrumentation: sink)
    let stream = await runtime.events()
    let run = Task { try await runtime.run("Create it") }
    for await event in stream {
      if case .permissionRequired = event { break }
      if case .error = event { break }
    }
    run.cancel()
    do {
      _ = try await run.value
      Issue.record("Expected cancellation")
    } catch let error as AgentError { #expect(error == .cancelled) }
    await runtime.finishEvents()
    #expect(sink.events.contains { $0.operation == .permission && $0.phase == .began })
    #expect(await tool.executions.isEmpty)
    expectBalanced(sink)
  }

  @Test func cancelledClarificationWaitClosesItsSpan() async throws {
    let sink = MockRuntimeInstrumentation()
    let model = ScriptedModelProvider(responses: [
      traceChoice("finish"), .clarification("Which item?"),
    ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([]),
      instrumentation: sink)
    let stream = await runtime.events()
    let run = Task { try await runtime.run("Find it") }
    for await event in stream {
      if case .clarificationRequested = event { break }
      if case .error = event { break }
    }
    run.cancel()
    do {
      _ = try await run.value
      Issue.record("Expected cancellation")
    } catch let error as AgentError { #expect(error == .cancelled) }
    await runtime.finishEvents()
    #expect(sink.events.contains { $0.operation == .clarification && $0.phase == .began })
    expectBalanced(sink)
  }

  @Test func retrievalIsTracedBeforePlanning() async throws {
    let sink = MockRuntimeInstrumentation()
    let model = ScriptedModelProvider(responses: [traceChoice("finish"), .text("Done")])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(
        model: model, embedding: MockEmbeddingProvider(), vectorStore: MockVectorStore()),
      tools: StaticToolSource([]), instrumentation: sink)
    _ = try await runtime.run("Search")
    expectBalanced(sink)
    let starts = sink.events.filter { $0.phase == .began }.map(\.operation)
    #expect(starts.prefix(3) == [.run, .retrieval, .planning])
  }

  @Test func oneSinkKeepsConcurrentRunsDistinct() async throws {
    let sink = MockRuntimeInstrumentation()
    func makeRuntime() throws -> AgentRuntime {
      try AgentRuntime(
        configuration: AgentConfiguration(
          model: ScriptedModelProvider(responses: [
            traceChoice("finish"), .text("Done"),
          ])), tools: StaticToolSource([]), instrumentation: sink)
    }
    let first = try makeRuntime()
    let second = try makeRuntime()
    async let a = first.run("First")
    async let b = second.run("Second")
    _ = try await (a, b)
    expectBalanced(sink, runs: 2)
  }
}
