import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

@Suite struct RuntimeWorkingMemoryTests {
  @Test func workflowBindingsAreObservableAndAvailableToLaterSteps() async throws {
    let read = MockTool(name: "read", permission: .readOnly, handler: { _ in "Budget review" })
    let echo = MockTool(
      name: "echo",
      schema: ToolSchema(
        parameters: [
          "text": ToolParameter(.string, description: "Earlier fact")
        ], required: ["text"]), handler: { $0.string("text") ?? "missing" })
    let workflow = Workflow(
      name: "facts", description: "Carry facts",
      steps: [
        .tool("meeting", "Read", "read"),
        .tool("echoed", "Use fact", "echo", ["text": .binding("meeting")]),
      ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: ScriptedModelProvider(responses: [])),
      tools: StaticToolSource([read, echo]), planner: StateMachinePlanner(workflow: workflow))
    #expect(await runtime.workingMemory().values.isEmpty)
    let stream = await runtime.events()
    let collected = Task { () -> [WorkingMemory] in
      var values: [WorkingMemory] = []
      for await event in stream {
        if case .workingMemoryUpdated(let value) = event { values.append(value) }
      }
      return values
    }
    _ = try await runtime.run("Prepare")
    await runtime.finishEvents()
    let snapshots = await collected.value
    #expect(snapshots.count == 3)
    #expect(snapshots[0].values.isEmpty)
    #expect(snapshots[1].value(for: "meeting") == .string("Budget review"))
    #expect(snapshots[2].orderedKeys == ["meeting", "echoed"])
    #expect(await echo.executions.first?.string("text") == "Budget review")
    var copy = await runtime.workingMemory()
    copy.removeAll()
    #expect(await runtime.workingMemory() == snapshots[2])
  }

  @Test func openPlanningRecordsSuccessfulToolFacts() async throws {
    let read = MockTool(name: "read", permission: .readOnly, handler: { _ in "Budget review" })
    let model = ScriptedModelProvider(responses: [
      .toolCall(
        ToolCall(
          id: "select", name: "choose_next_action",
          arguments: ToolArguments(["action": .string("read")]))),
      .toolCall(
        ToolCall(
          id: "finish", name: "choose_next_action",
          arguments: ToolArguments(["action": .string("finish")]))),
      .text("Budget review"),
    ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([read]))
    _ = try await runtime.run("What is the meeting?")
    let memory = await runtime.workingMemory()
    #expect(memory.values.count == 1)
    #expect(memory.values.values.contains(.string("Budget review")))
  }

  @Test func openFactsPreserveObservationTextAlongsideTypedAndCustomFacts() throws {
    var context = AgentContext(goal: "Convert temperature")
    context.mode = .open
    context.workingMemory.set(.string("only this task"), forKey: "task")
    let call = ToolCall(id: "conversion#1", name: "convert_temperature", arguments: ToolArguments())
    context.pending = AgentContext.PendingStep(
      stepID: call.id, invocation: ToolInvocation(tool: call.name), attempt: 0, isAlternative: false
    )
    let observation = ToolObservation(
      call: call,
      result: ToolResult(
        callID: call.id, toolName: call.name, text: "68.0 degrees Fahrenheit",
        structured: .double(68)))
    _ = try StateMachinePlanner().observe(observation, context: &context)
    let facts = context.factsText()
    #expect(facts.contains("convert_temperature: 68.0 degrees Fahrenheit"))
    #expect(facts.contains("task: only this task"))
    #expect(!facts.contains("conversion#1:"))
    #expect(context.workingMemory.value(for: call.id) == .double(68))
  }

  @Test func taskMemoryResetsBetweenRunsAndIsNotWrittenToPersistentMemory() async throws {
    let persistent = MockMemoryStore()
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(
        model: ScriptedModelProvider(responses: []), memory: persistent),
      tools: StaticToolSource([]), planner: SeedPlanner())
    _ = try await runtime.run("seed")
    #expect(await runtime.workingMemory().value(for: "task") == .string("only this task"))
    _ = try await runtime.run("fresh")
    #expect(await runtime.workingMemory().values.isEmpty)
    #expect(await persistent.all.isEmpty)
  }

  @Test func mutationsBeforePlannerFailureArePublishedAndRetained() async throws {
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: ScriptedModelProvider(responses: [])),
      tools: StaticToolSource([]), planner: SeedPlanner())
    let stream = await runtime.events()
    let events = Task { () -> [String] in
      var output: [String] = []
      for await event in stream {
        if case .workingMemoryUpdated(let memory) = event, memory.value(for: "failure") != nil {
          output.append("facts")
        }
        if case .error = event { output.append("error") }
      }
      return output
    }
    await #expect(throws: AgentError.toolFailed(tool: "test", message: "planned failure")) {
      try await runtime.run("fail")
    }
    await runtime.finishEvents()
    #expect(await events.value == ["facts", "error"])
    #expect(await runtime.workingMemory().value(for: "failure") == .bool(true))
  }

  @Test func taskFactsCannotApproveAWritingTool() async throws {
    let write = MockTool(name: "write", permission: .userConfirmation)
    let workflow = Workflow(
      name: "write", description: "Write", steps: [.tool("write", "Write", "write")])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: ScriptedModelProvider(responses: [])),
      tools: StaticToolSource([write]),
      planner: SeedPlanner(delegate: StateMachinePlanner(workflow: workflow)))
    let stream = await runtime.events()
    let task = Task { try await runtime.run("approve") }
    for await event in stream {
      if case .permissionRequired(let call) = event {
        #expect(await runtime.workingMemory().value(for: "approved") == .bool(true))
        await runtime.resolvePermission(callID: call.id, approved: false)
        break
      }
    }
    await #expect(throws: AgentError.permissionDenied(tool: "write")) { try await task.value }
    #expect(await write.executions.isEmpty)
  }
}

private struct SeedPlanner: AgentPlanner {
  var delegate: StateMachinePlanner?
  func plan(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    async throws -> AgentPlan
  {
    if context.goal == "seed" {
      context.workingMemory.set(.string("only this task"), forKey: "task")
    }
    if context.goal == "approve" { context.workingMemory.set(.bool(true), forKey: "approved") }
    if let delegate {
      return try await delegate.plan(context: &context, tools: tools, model: model)
    }
    return AgentPlan(steps: [])
  }
  func next(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    async throws -> PlannerDecision
  {
    if context.goal == "fail" {
      context.workingMemory.set(.bool(true), forKey: "failure")
      throw AgentError.toolFailed(tool: "test", message: "planned failure")
    }
    if let delegate {
      return try await delegate.next(context: &context, tools: tools, model: model)
    }
    return .complete("Done")
  }
  func observe(_ observation: ToolObservation, context: inout AgentContext) throws -> PlanRevision {
    try delegate?.observe(observation, context: &context) ?? .continue
  }
  func handleFailure(_ error: AgentError, context: inout AgentContext) throws -> PlanRevision {
    throw error
  }
}
