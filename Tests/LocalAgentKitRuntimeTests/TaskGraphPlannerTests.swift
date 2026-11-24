import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

private actor GraphGate {
  var count = 0
  var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
  var releases: [AsyncStream<Void>.Continuation] = []
  func pause(_ value: String) async throws -> String {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    releases.append(continuation)
    count += 1
    let ready = waiting.filter { count >= $0.0 }
    waiting.removeAll { count >= $0.0 }
    for (_, waiter) in ready { waiter.resume() }
    for await _ in stream {}
    try Task.checkCancellation()
    return value
  }
  func entered(_ target: Int) async {
    if count < target { await withCheckedContinuation { waiting.append((target, $0)) } }
  }
  func releaseAll() {
    for continuation in releases { continuation.finish() }
    releases = []
  }
}

private func graphRuntime(
  _ graph: TaskGraph, tools: [any AgentTool], model: any LocalModelProvider = MockModelProvider(),
  width: Int = 4, limits: ExecutionLimits = .default
) throws -> AgentRuntime {
  try AgentRuntime(
    configuration: AgentConfiguration(model: model, limits: limits), tools: StaticToolSource(tools),
    planner: TaskGraphPlanner(graph: graph, maxParallelism: width))
}

private struct GraphDeny: PermissionGate {
  func decide(for call: ToolCall, tool: ToolDescriptor) -> PermissionDecision { .denied }
}

private struct GraphFacts: AgentTool {
  let name = "facts"
  let description = "Synthetic facts"
  let schema = ToolSchema.empty
  let permission = ToolPermission.readOnly
  let isParallelSafe = true
  let isCancellable = true
  let value: JSONValue
  var empty = false
  func execute(arguments: ToolArguments) -> ToolResult {
    ToolResult(
      callID: "", toolName: name, text: "Synthetic facts", structured: value, isEmpty: empty)
  }
}

@Suite struct TaskGraphPlannerTests {
  @Test func fanInInfersBindingsReordersDeclarationsAndWaitsForBothRoots() async throws {
    let gate = GraphGate()
    let left = MockTool(name: "left", handler: { _ in try await gate.pause("A") })
    let right = MockTool(name: "right", handler: { _ in try await gate.pause("B") })
    let join = MockTool(
      name: "join",
      schema: ToolSchema(
        parameters: [
          "a": ToolParameter(.string, description: "First"),
          "b": ToolParameter(.string, description: "Second"),
        ], required: ["a", "b"]), handler: { ($0.string("a") ?? "") + ($0.string("b") ?? "") })
    let graph = TaskGraph(
      name: "fan-in",
      nodes: [
        TaskNode(
          .tool(
            "join", "Join", "join", ["a": .binding("first"), "b": .binding("second")], retries: 0)),
        TaskNode(.respond("answer", instruction: "Answer from joined facts")),
        TaskNode(.tool("a", "Read A", "left", binds: "first", retries: 0)),
        TaskNode(.tool("b", "Read B", "right", binds: "second", retries: 0)),
      ])
    let model = ScriptedModelProvider(responses: [.text("AB")])
    let runtime = try graphRuntime(graph, tools: [left, right, join], model: model)
    let events = await runtime.events()
    let run = Task { try await runtime.run("Join two independent facts") }
    await gate.entered(2)
    #expect(await join.executions.isEmpty)
    await gate.releaseAll()
    let response = try await run.value
    #expect(response.text == "AB" && response.toolCallCount == 3 && response.iterations == 3)
    #expect(await join.executions.first?.string("a") == "A")
    #expect(await join.executions.first?.string("b") == "B")
    #expect(await model.requests.count == 1)
    await runtime.finishEvents()
    var plan: AgentPlan?
    var correlated: [String] = []
    for await event in events {
      if case .planCreated(let value) = event { plan = value }
      if case .toolStarted(let call) = event, let step = call.planStepID { correlated.append(step) }
    }
    #expect(Set(correlated) == ["a", "b", "join"])
    #expect(plan?.steps.map(\.id) == ["a", "b", "join", "answer"])
    #expect(plan?.steps.first(where: { $0.id == "join" })?.dependsOn == ["a", "b"])
    #expect(plan?.steps.last?.dependsOn == ["a", "b", "join"])
  }

  @Test func configuredWidthCreatesStableReadyWaves() async throws {
    let gate = GraphGate()
    let tools = (0..<3).map { index in
      MockTool(name: "read_\(index)", handler: { _ in try await gate.pause("\(index)") })
    }
    let graph = TaskGraph(
      name: "width",
      nodes: tools.enumerated().map {
        TaskNode(.tool("n\($0.offset)", "Read", $0.element.name, retries: 0))
      })
    let runtime = try graphRuntime(graph, tools: tools, width: 2)
    let run = Task { try await runtime.run("Read all") }
    await gate.entered(2)
    #expect(await tools[2].executions.isEmpty)
    await gate.releaseAll()
    await gate.entered(3)
    await gate.releaseAll()
    #expect(try await run.value.toolCallCount == 3)
    #expect(await tools[0].executions.count == 1)
  }

  @Test(arguments: [
    "cycle", "implicit_cycle", "self", "unknown_dependency", "duplicate_id", "duplicate_alias",
    "bad_id", "unknown_binding", "missing_tool", "missing_argument", "bad_literal", "two_answers",
    "answer_binding", "bad_path", "empty", "empty_name",
  ])
  func malformedGraphsFailBeforeGenerationOrExecution(_ kind: String) async throws {
    let tool = MockTool(
      name: "read",
      schema: ToolSchema(
        parameters: ["x": ToolParameter(.integer, description: "Count")], required: ["x"]))
    let a = WorkflowStep.tool("a", "A", "read", ["x": .literal(1)], retries: 0)
    let b = WorkflowStep.tool("b", "B", "read", ["x": .literal(2)], retries: 0)
    var nodes = [TaskNode(a), TaskNode(b)]
    switch kind {
    case "cycle": nodes = [TaskNode(a, dependsOn: ["b"]), TaskNode(b, dependsOn: ["a"])]
    case "implicit_cycle":
      nodes = [
        TaskNode(.tool("a", "A", "read", ["x": .binding("b")])),
        TaskNode(.tool("b", "B", "read", ["x": .binding("a")])),
      ]
    case "self": nodes = [TaskNode(a, dependsOn: ["a"])]
    case "unknown_dependency": nodes = [TaskNode(a, dependsOn: ["unknown"])]
    case "duplicate_id": nodes = [TaskNode(a), TaskNode(a)]
    case "duplicate_alias":
      nodes = [TaskNode(a), TaskNode(.tool("b", "B", "read", ["x": .literal(1)], binds: "a"))]
    case "bad_id": nodes = [TaskNode(.tool("bad:id", "Bad", "read", ["x": .literal(1)]))]
    case "unknown_binding": nodes = [TaskNode(.tool("a", "A", "read", ["x": .binding("unknown")]))]
    case "missing_tool": nodes = [TaskNode(.tool("a", "A", "unknown"))]
    case "missing_argument": nodes = [TaskNode(.tool("a", "A", "read"))]
    case "bad_literal": nodes = [TaskNode(.tool("a", "A", "read", ["x": .literal("wrong")]))]
    case "two_answers":
      nodes = [
        TaskNode(.respond("one", instruction: "One")),
        TaskNode(.respond("two", instruction: "Two")),
      ]
    case "answer_binding":
      nodes = [
        TaskNode(.respond("answer", instruction: "Answer")),
        TaskNode(.tool("a", "A", "read", ["x": .binding("answer")])),
      ]
    case "bad_path":
      nodes = [TaskNode(a), TaskNode(.tool("b", "B", "read", ["x": .binding("a..x")]))]
    case "empty": nodes = []
    default: break
    }
    let model = MockModelProvider()
    let runtime = try graphRuntime(
      TaskGraph(name: kind == "empty_name" ? " " : "invalid", nodes: nodes), tools: [tool],
      model: model)
    do {
      _ = try await runtime.run("Validate graph")
      Issue.record("Expected graph rejection")
    } catch let error as AgentError {
      guard case .invalidConfiguration(.invalidWorkflow) = error else {
        Issue.record("Unexpected \(error)")
        return
      }
    }
    #expect(await tool.executions.isEmpty)
    #expect(await model.requests.isEmpty)
  }

  @Test func guardReferencesInferDependenciesAndSkippedNodesReleaseTheAnswer() async throws {
    let facts = GraphFacts(value: .array([]), empty: true)
    let write = MockTool(name: "write")
    let graph = TaskGraph(
      name: "guards",
      nodes: [
        TaskNode(.tool("write", "Write", "write", condition: .not(.isEmpty("data")), retries: 0)),
        TaskNode(.tool("read", "Read", "facts", binds: "data", onEmpty: .skip, retries: 0)),
        TaskNode(.respond(instruction: "Explain missing facts")),
      ])
    let model = ScriptedModelProvider(responses: [.text("No data")])
    let response = try await graphRuntime(graph, tools: [facts, write], model: model).run(
      "Read and conditionally write")
    #expect(response.text == "No data" && response.toolCallCount == 1)
    #expect(await write.executions.isEmpty)
  }

  @Test func recoveryBearingNodesRetainSerialRetriesAndAlternatives() async throws {
    let broken = MockTool(
      name: "broken",
      handler: { _ in throw AgentError.toolFailed(tool: "broken", message: "Unavailable") })
    let fallback = MockTool(name: "fallback", handler: { _ in "Recovered" })
    let other = MockTool(name: "other")
    let graph = TaskGraph(
      name: "recovery",
      nodes: [
        TaskNode(
          .tool("read", "Read", "broken", alternative: ToolInvocation(tool: "fallback"), retries: 1)
        ),
        TaskNode(.tool("other", "Other", "other", retries: 0)),
      ])
    let response = try await graphRuntime(graph, tools: [broken, fallback, other]).run(
      "Recover a read")
    #expect(response.toolCallCount == 4)
    #expect(await broken.executions.count == 2)
    #expect(await fallback.executions.count == 1)
    #expect(await other.executions.count == 1)
  }

  @Test func aDeniedNodeCannotUseItsDeclaredAlternative() async throws {
    let write = MockTool(name: "write", permission: .userConfirmation)
    let bypass = MockTool(name: "bypass")
    let graph = TaskGraph(
      name: "permission",
      nodes: [
        TaskNode(
          .tool(
            "write", "Write", "write", alternative: ToolInvocation(tool: "bypass"), onFailure: .skip
          ))
      ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: MockModelProvider()),
      tools: StaticToolSource([write, bypass]), planner: TaskGraphPlanner(graph: graph),
      gate: GraphDeny())
    await #expect(throws: AgentError.permissionDenied(tool: "write")) {
      try await runtime.run("Write")
    }
    #expect(await write.executions.isEmpty)
    #expect(await bypass.executions.isEmpty)
  }

  @Test func explicitDependenciesMakeFactsAvailableToNarrowModelArguments() async throws {
    let read = MockTool(name: "read", handler: { _ in "Ada" })
    let write = MockTool(
      name: "write",
      schema: ToolSchema(
        parameters: ["name": ToolParameter(.string, description: "Observed name")],
        required: ["name"]))
    let graph = TaskGraph(
      name: "model",
      nodes: [
        TaskNode(
          .tool(
            "write", "Use name", "write", ["name": .model(hint: "Use the observed name")],
            retries: 0), dependsOn: ["read"]),
        TaskNode(.tool("read", "Read name", "read", retries: 0)),
      ])
    let model = ScriptedModelProvider(responses: [
      .toolCall(
        ToolCall(
          id: "args", name: "provide_write_arguments", arguments: ToolArguments(["name": "Ada"])))
    ])
    _ = try await graphRuntime(graph, tools: [read, write], model: model).run(
      "Read and use the name")
    #expect(await write.executions.first?.string("name") == "Ada")
    #expect(await model.requests.first?.messages.last?.content.contains("Ada") == true)
  }

  @Test func incompatibleBoundFactsFailWithoutModelSubstitution() async throws {
    let facts = GraphFacts(value: .object(["count": .string("wrong")]))
    let consume = MockTool(
      name: "consume",
      schema: ToolSchema(
        parameters: ["count": ToolParameter(.integer, description: "Count")], required: ["count"]))
    let graph = TaskGraph(
      name: "typed",
      nodes: [
        TaskNode(.tool("read", "Read", "facts", retries: 0)),
        TaskNode(.tool("use", "Use", "consume", ["count": .binding("read.count")], retries: 0)),
      ])
    let model = MockModelProvider()
    let runtime = try graphRuntime(graph, tools: [facts, consume], model: model)
    await #expect(throws: AgentError.self) { try await runtime.run("Use the count") }
    #expect(await consume.executions.isEmpty)
    #expect(await model.requests.isEmpty)
  }
}
