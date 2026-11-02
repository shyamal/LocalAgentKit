import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

private func proposedStep(_ tool: String, summary: String = "Do the task") -> JSONValue {
  .object([
    "tool": .string(tool), "summary": .string(summary),
    "instruction": .string("Use the goal and earlier observations."),
  ])
}

private func proposal(_ steps: [JSONValue], answer: String = "Answer from the observations.")
  -> ModelResponse
{
  .toolCall(
    ToolCall(
      id: "plan", name: "propose_tool_plan",
      arguments: ToolArguments([
        "steps": .array(steps), "answer_instruction": .string(answer),
      ])))
}

private func experimentalRuntime(
  _ model: any LocalModelProvider, tools: [any AgentTool] = [],
  gate: (any PermissionGate)? = nil, limits: ExecutionLimits = .default,
  planner: (any AgentPlanner)? = nil
) throws -> AgentRuntime {
  try AgentRuntime(
    configuration: AgentConfiguration(model: model, limits: limits, planner: .modelDriven),
    tools: StaticToolSource(tools), planner: planner, gate: gate)
}

private func failure(_ runtime: AgentRuntime, goal: String = "Do the task") async -> AgentError? {
  do {
    _ = try await runtime.run(goal)
    return nil
  } catch let error as AgentError {
    return error
  } catch {
    Issue.record("Unexpected untyped error: \(error)")
    return nil
  }
}

private struct DenyPlanTool: PermissionGate {
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision { .denied }
}

@Suite struct ModelDrivenPlannerTests {
  @Test func configuredPlannerProposesThenExecutesAWholeSequence() async throws {
    let read = MockTool(name: "read_name", permission: .readOnly, handler: { _ in "Ada" })
    let write = MockTool(
      name: "format_name",
      schema: ToolSchema(
        parameters: ["name": ToolParameter(.string, description: "The name.")], required: ["name"]),
      handler: { $0.string("name") ?? "missing" })
    let model = ScriptedModelProvider(responses: [
      proposal([proposedStep("read_name"), proposedStep("format_name")]),
      .toolCall(
        ToolCall(
          id: "args", name: "provide_format_name_arguments",
          arguments: ToolArguments(["name": .string("Ada")]))),
      .text("Ada is ready."),
    ])
    let runtime = try experimentalRuntime(model, tools: [read, write])
    let stream = await runtime.events()
    let collector = Task { () -> [AgentEvent] in
      var events: [AgentEvent] = []
      for await event in stream { events.append(event) }
      return events
    }
    do {
      let response = try await runtime.run("Read the name and format it.")
      await runtime.finishEvents()
      let events = await collector.value
      #expect(response.text == "Ada is ready.")
      #expect(response.toolCallCount == 2)
      #expect(await read.executions.count == 1)
      #expect(await write.executions.first?.string("name") == "Ada")
      let plans = events.compactMap { event -> AgentPlan? in
        if case .planCreated(let plan) = event { return plan }
        return nil
      }
      #expect(plans.count == 1)
      #expect(plans.first?.steps.map(\.toolName) == ["read_name", "format_name", nil])
      let requests = await model.requests
      #expect(requests.count == 3)
      #expect(requests.first?.tools.first?.name == "propose_tool_plan")
      #expect(requests[1].messages.contains { $0.content.contains("Ada") })
      #expect(events.filter { if case .contextUtilization = $0 { true } else { false } }.count == 3)
    } catch {
      await runtime.finishEvents()
      _ = await collector.value
      throw error
    }
  }

  @Test func aPlanCanAnswerWithoutTools() async throws {
    let model = ScriptedModelProvider(responses: [proposal([]), .text("Hello.")])
    let runtime = try experimentalRuntime(model)
    let response = try await runtime.run("Say hello")
    #expect(response.text == "Hello.")
    #expect(response.toolCallCount == 0)
    #expect(response.iterations == 1)
  }

  @Test(arguments: ["unknown", "too_many", "blank_summary", "blank_answer", "malformed"])
  func invalidPlansNeverExecuteTools(_ kind: String) async throws {
    let tool = MockTool(name: "read_item")
    let response: ModelResponse
    switch kind {
    case "unknown": response = proposal([proposedStep("not_registered")])
    case "too_many": response = proposal([proposedStep("read_item"), proposedStep("read_item")])
    case "blank_summary": response = proposal([proposedStep("read_item", summary: " \n")])
    case "blank_answer": response = proposal([], answer: " ")
    default:
      response = .toolCall(ToolCall(id: "plan", name: "propose_tool_plan"))
    }
    let model = ScriptedModelProvider(responses: [response])
    let runtime = try experimentalRuntime(
      model, tools: [tool], planner: ModelDrivenPlanner(maxSteps: 1, maxRepairs: 0))
    let error = await failure(runtime)
    guard case .invalidArguments = error else {
      Issue.record("Expected invalidArguments, got \(String(describing: error))")
      return
    }
    #expect(await tool.executions.isEmpty)
    #expect(await model.requests.count == 1)
  }

  @Test func aProposedWriteStillRequiresHumanPermission() async throws {
    let write = MockTool(name: "create_item", permission: .userConfirmation)
    let model = ScriptedModelProvider(responses: [proposal([proposedStep("create_item")])])
    let runtime = try experimentalRuntime(model, tools: [write], gate: DenyPlanTool())
    #expect(await failure(runtime) == .permissionDenied(tool: "create_item"))
    #expect(await write.executions.isEmpty)
    #expect(await model.requests.count == 1)
  }

  @Test func planningRefusalIsTerminalWithoutRepair() async throws {
    let refusal = GuardrailRefusal(explanation: "No.")
    let model = ScriptedModelProvider(responses: [.refused(refusal), proposal([])])
    let runtime = try experimentalRuntime(model)
    #expect(await failure(runtime) == .guardrailRefusal(refusal))
    #expect(await model.requests.count == 1)
  }

  @Test func planningUsesContextBudgetBeforeGeneration() async throws {
    let model = ScriptedModelProvider(responses: [proposal([])])
    let runtime = try experimentalRuntime(model, limits: ExecutionLimits(maxContextTokens: 1))
    #expect(await failure(runtime) == .contextLimitExceeded)
    #expect(await model.requests.isEmpty)
  }

  @Test func aPlannedWriteSuspendsUntilTheHumanApproves() async throws {
    let write = MockTool(name: "create_item", permission: .userConfirmation)
    let model = ScriptedModelProvider(responses: [
      proposal([proposedStep("create_item")]), .text("Saved."),
    ])
    let runtime = try experimentalRuntime(model, tools: [write])
    let stream = await runtime.events()
    let run = Task { try await runtime.run("Save an item") }
    var pending: ToolCall?
    for await event in stream {
      if case .permissionRequired(let call) = event {
        pending = call
        break
      }
      if case .error = event { break }
    }
    guard let pending else {
      run.cancel()
      _ = try? await run.value
      await runtime.finishEvents()
      Issue.record("Expected a pending permission request")
      return
    }
    #expect(await write.executions.isEmpty)
    #expect(await runtime.resolvePermission(callID: pending.id, approved: true))
    let response = try await run.value
    await runtime.finishEvents()
    #expect(response.text == "Saved.")
    #expect(await write.executions.count == 1)
  }

  @Test func malformedProposalCanBeRepairedWithinTheBound() async throws {
    let model = ScriptedModelProvider(responses: [
      .toolCall(ToolCall(id: "bad", name: "propose_tool_plan")),
      proposal([]), .text("Ready."),
    ])
    let runtime = try experimentalRuntime(model)
    #expect(try await runtime.run("Say ready").text == "Ready.")
    #expect(await model.requests.count == 3)
  }

  @Test func planningCallHasItsOwnDeadline() async throws {
    let model = ScriptedModelProvider([.hang])
    let runtime = try experimentalRuntime(
      model, limits: ExecutionLimits(maxModelCallDuration: .milliseconds(20)))
    #expect(await failure(runtime) == .executionTimeout(.modelCall))
  }

  @Test func cancellationDuringPlanningIsTyped() async throws {
    let model = ScriptedModelProvider([.hang])
    let runtime = try experimentalRuntime(model)
    let run = Task { await failure(runtime) }
    while await model.requests.isEmpty { await Task.yield() }
    run.cancel()
    #expect(await run.value == .cancelled)
  }

  @Test func aFailedStepDoesNotTriggerOpenEndedReplanning() async throws {
    let tool = MockTool(
      name: "read_item",
      handler: { _ in
        throw AgentError.toolFailed(tool: "read_item", message: "Unavailable")
      })
    let model = ScriptedModelProvider(responses: [proposal([proposedStep("read_item")])])
    let runtime = try experimentalRuntime(model, tools: [tool])
    #expect(await failure(runtime) == .toolFailed(tool: "read_item", message: "Unavailable"))
    #expect(await tool.executions.count == 1)
    #expect(await model.requests.count == 1)
  }

  @Test func runtimeIterationLimitStillBoundsGeneratedPlans() async throws {
    let tool = MockTool(name: "read_item")
    let model = ScriptedModelProvider(responses: [proposal([proposedStep("read_item")])])
    let runtime = try experimentalRuntime(
      model, tools: [tool], limits: ExecutionLimits(maxIterations: 1))
    #expect(await failure(runtime) == .maximumIterationsReached(limit: 1))
    #expect(await tool.executions.count == 1)
  }

  @Test func defaultPlannerRemainsTheStateMachine() async throws {
    let model = ScriptedModelProvider(responses: [
      .toolCall(
        ToolCall(
          id: "choice", name: "choose_next_action",
          arguments: ToolArguments(["action": .string("finish")]))),
      .text("Default."),
    ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([]))
    #expect(try await runtime.run("Hello").text == "Default.")
    #expect(await model.requests.first?.tools.first?.name == "choose_next_action")
  }
}
