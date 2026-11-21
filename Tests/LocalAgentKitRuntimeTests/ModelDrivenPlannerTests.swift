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
    let runtime = try experimentalRuntime(
      model, tools: [tool], planner: ModelDrivenPlanner(maxReplans: 0))
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

private struct PlanFacts: AgentTool {
  let value: JSONValue
  var empty = false
  let name = "read_facts"
  let description = "Read structured task facts."
  let schema = ToolSchema.empty
  let permission = ToolPermission.none
  let isParallelSafe = true
  let isCancellable = true
  func execute(arguments: ToolArguments) async throws -> ToolResult {
    ToolResult(callID: "", toolName: name, text: "Task facts", structured: value, isEmpty: empty)
  }
}

private func advancedStep(_ name: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
  var result: [String: JSONValue] = [
    "tool": .string(name), "summary": "Planned step", "instruction": "Use the observed facts.",
  ]
  result.merge(fields) { _, new in new }
  return .object(result)
}

private func source(_ name: String, _ kind: String, _ value: String) -> JSONValue {
  .object(["name": .string(name), "source": .string(kind), "value": .string(value)])
}

private func clause(_ path: String, _ operation: String, _ value: String? = nil) -> JSONValue {
  var result: [String: JSONValue] = ["reference": .string(path), "operator": .string(operation)]
  if let value { result["value_json"] = .string(value) }
  return .object(result)
}

extension ModelDrivenPlannerTests {
  @Test func generatedBindingsCarryExactStructuredFactsWithoutArgumentGeneration() async throws {
    let facts = PlanFacts(value: .object(["count": .int(42)]))
    let consume = MockTool(
      name: "consume",
      schema: ToolSchema(
        parameters: ["count": ToolParameter(.integer, description: "Observed count.")],
        required: ["count"]))
    let model = ScriptedModelProvider(responses: [
      proposal([
        advancedStep("read_facts"),
        advancedStep(
          "consume", ["arguments": .array([source("count", "binding", "step_1.count")])]),
      ]), .text("Done"),
    ])
    let runtime = try experimentalRuntime(model, tools: [facts, consume])
    #expect(try await runtime.run("Use the count").text == "Done")
    #expect(await consume.executions.first?.int("count") == 42)
    #expect(await model.requests.count == 2)
    let catalog = await model.requests.first?.messages.last?.content
    #expect(catalog?.contains("count (required") == true)
  }

  @Test func conditionalPathsUseObservedFactsInsteadOfPromptInstructions() async throws {
    let facts = PlanFacts(value: .object(["approved": .bool(false)]))
    let forbidden = MockTool(name: "approved_path")
    let fallback = MockTool(name: "fallback_path")
    let model = ScriptedModelProvider(responses: [
      proposal([
        advancedStep("read_facts"),
        advancedStep(
          "approved_path", ["conditions": .array([clause("step_1.approved", "equals", "true")])]),
        advancedStep(
          "fallback_path",
          [
            "conditions": .array([
              clause("step_1.approved", "equals", "false"), clause("step_1.absent", "exists"),
            ]), "condition_mode": "any",
          ]),
      ]), .text("Used fallback"),
    ])
    _ = try await experimentalRuntime(model, tools: [facts, forbidden, fallback]).run(
      "Choose a path")
    #expect(await forbidden.executions.isEmpty)
    #expect(await fallback.executions.count == 1)
    #expect(await model.requests.count == 2)
  }

  @Test(arguments: [
    "exists", "is_empty", "not_empty", "equals", "less_than", "at_most", "at_least", "greater_than",
  ])
  func generatedGuardOperatorsAreEvaluatedInCode(_ operation: String) async throws {
    let facts = PlanFacts(value: .int(5))
    let selected = MockTool(name: "selected")
    let value = ["exists", "is_empty", "not_empty"].contains(operation) ? nil : "5"
    let model = ScriptedModelProvider(responses: [
      proposal([
        advancedStep("read_facts"),
        advancedStep("selected", ["conditions": .array([clause("step_1", operation, value)])]),
      ]), .text("Done"),
    ])
    _ = try await experimentalRuntime(model, tools: [facts, selected]).run("Compare the value")
    let expected = ["exists", "not_empty", "equals", "at_most", "at_least"].contains(operation)
    #expect(await selected.executions.count == (expected ? 1 : 0))
  }

  @Test func emptyResultPolicyPermitsAGuardedFollowup() async throws {
    let facts = PlanFacts(value: .array([]), empty: true)
    let fallback = MockTool(name: "fallback")
    let model = ScriptedModelProvider(responses: [
      proposal([
        advancedStep("read_facts", ["on_empty": "skip"]),
        advancedStep("fallback", ["conditions": .array([clause("step_1", "is_empty")])]),
      ]), .text("Used fallback"),
    ])
    _ = try await experimentalRuntime(model, tools: [facts, fallback]).run("Find a fallback")
    #expect(await fallback.executions.count == 1)
  }

  @Test func aMissingBindingFailsWithoutModelSubstitution() async throws {
    let facts = PlanFacts(value: .object([:]))
    let write = MockTool(
      name: "write",
      schema: ToolSchema(
        parameters: ["value": ToolParameter(.string, description: "Value.")], required: ["value"]))
    let model = ScriptedModelProvider(responses: [
      proposal([
        advancedStep("read_facts"),
        advancedStep(
          "write", ["arguments": .array([source("value", "binding", "step_1.missing")])]),
      ])
    ])
    let runtime = try experimentalRuntime(model, tools: [facts, write])
    guard case .invalidArguments = await failure(runtime) else {
      Issue.record("Expected a missing binding error")
      return
    }
    #expect(await write.executions.isEmpty)
    #expect(await model.requests.count == 1)
  }

  @Test func generatedLiteralsAndRetryBoundsUseTheExistingExecutor() async throws {
    actor Attempts {
      var count = 0
      func perform() throws -> String {
        count += 1
        if count < 2 {
          throw AgentError.toolFailed(tool: "retry", message: "Transient fixture failure")
        }
        return "OK"
      }
    }
    let attempts = Attempts()
    let tool = MockTool(
      name: "retry",
      schema: ToolSchema(
        parameters: ["value": ToolParameter(.string, description: "Value.")], required: ["value"]),
      handler: { _ in try await attempts.perform() })
    let model = ScriptedModelProvider(responses: [
      proposal([
        advancedStep(
          "retry",
          [
            "arguments": .array([source("value", "literal", "\"Exact value\"")]), "retries": 2,
          ])
      ]), .text("Done"),
    ])
    _ = try await experimentalRuntime(model, tools: [tool]).run("Retry the operation")
    #expect(await tool.executions.count == 2)
    #expect(await tool.executions.allSatisfy { $0.string("value") == "Exact value" })
    #expect(await model.requests.count == 2)
  }

  @Test func aGeneratedRetryNeverRoutesAroundPermissionDenial() async throws {
    let write = MockTool(name: "protected_write", permission: .userConfirmation)
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("protected_write", ["retries": 2, "on_empty": "skip"])])
    ])
    let runtime = try experimentalRuntime(model, tools: [write], gate: DenyPlanTool())
    #expect(await failure(runtime) == .permissionDenied(tool: "protected_write"))
    #expect(await write.executions.isEmpty)
    #expect(await model.requests.count == 1)
  }

  @Test(arguments: [
    "forward", "empty_path", "unknown_parameter", "duplicate", "wrong_literal", "bad_json",
    "oversized", "too_many_guards", "unknown_operator", "extra_comparison", "nonnumeric",
    "excess_retries",
  ])
  func malformedExpressionsRejectTheWholePlanBeforeExecution(_ kind: String) async throws {
    let tool = MockTool(
      name: "consume",
      schema: ToolSchema(
        parameters: ["count": ToolParameter(.integer, description: "Count.")], required: ["count"]))
    var fields: [String: JSONValue] = [:]
    switch kind {
    case "forward": fields["arguments"] = .array([source("count", "binding", "step_2")])
    case "empty_path": fields["arguments"] = .array([source("count", "binding", "step_1..count")])
    case "unknown_parameter": fields["arguments"] = .array([source("missing", "literal", "1")])
    case "duplicate":
      fields["arguments"] = .array([
        source("count", "literal", "1"), source("count", "literal", "2"),
      ])
    case "wrong_literal": fields["arguments"] = .array([source("count", "literal", "\"text\"")])
    case "bad_json": fields["arguments"] = .array([source("count", "literal", "{")])
    case "oversized":
      fields["arguments"] = .array([
        source("count", "literal", String(repeating: "1", count: 16_385))
      ])
    case "too_many_guards":
      fields["conditions"] = .array(Array(repeating: clause("step_1", "exists"), count: 9))
    case "unknown_operator": fields["conditions"] = .array([clause("step_1", "execute_script")])
    case "extra_comparison": fields["conditions"] = .array([clause("step_1", "exists", "1")])
    case "nonnumeric": fields["conditions"] = .array([clause("step_1", "less_than", "\"text\"")])
    default: fields["retries"] = 3
    }
    let facts = MockTool(name: "read_facts")
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("read_facts"), advancedStep("consume", fields)])
    ])
    let runtime = try experimentalRuntime(
      model, tools: [facts, tool], planner: ModelDrivenPlanner(maxRepairs: 0))
    guard case .invalidArguments = await failure(runtime) else {
      Issue.record("Expected invalidArguments for \(kind)")
      return
    }
    #expect(await facts.executions.isEmpty)
    #expect(await tool.executions.isEmpty)
    #expect(await model.requests.count == 1)
  }
}

extension ModelDrivenPlannerTests {
  @Test func generatedRetriesCannotOverrideLoopProtection() async throws {
    let tool = MockTool(
      name: "retry",
      handler: { _ in
        throw AgentError.toolFailed(tool: "retry", message: "Still unavailable")
      })
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("retry", ["retries": 2])])
    ])
    let runtime = try experimentalRuntime(model, tools: [tool])
    #expect(await failure(runtime) == .loopDetected(tool: "retry"))
    #expect(await tool.executions.count == 2)
    #expect(await model.requests.count == 1)
  }
}

extension ModelDrivenPlannerTests {
  @Test func incompatibleBoundFactsCannotBeRewrittenByArgumentRepair() async throws {
    let facts = PlanFacts(value: .object(["count": .string("not a count")]))
    let write = MockTool(
      name: "write",
      schema: ToolSchema(
        parameters: ["count": ToolParameter(.integer, description: "Observed count.")],
        required: ["count"]))
    let model = ScriptedModelProvider(responses: [
      proposal([
        advancedStep("read_facts"),
        advancedStep("write", ["arguments": .array([source("count", "binding", "step_1.count")])]),
      ])
    ])
    let runtime = try experimentalRuntime(model, tools: [facts, write])
    guard case .invalidArguments = await failure(runtime) else {
      Issue.record("Expected an incompatible binding error")
      return
    }
    #expect(await write.executions.isEmpty)
    #expect(await model.requests.count == 1)
  }
}

private struct ApprovePlanTool: PermissionGate {
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision { .approved }
}

extension ModelDrivenPlannerTests {
  @Test func failureRevisesOnlyTheSuffixAndPublishesTheNewPlan() async throws {
    let read = MockTool(name: "read", handler: { _ in "Ada" })
    let broken = MockTool(
      name: "broken",
      handler: { _ in
        throw AgentError.toolFailed(tool: "broken", message: "Source unavailable")
      })
    let obsolete = MockTool(name: "obsolete")
    let recovery = MockTool(
      name: "recover",
      schema: ToolSchema(
        parameters: ["name": ToolParameter(.string, description: "Observed name.")],
        required: ["name"]))
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("read"), advancedStep("broken"), advancedStep("obsolete")]),
      proposal([
        advancedStep("recover", ["arguments": .array([source("name", "binding", "step_1")])])
      ]),
      .text("Recovered"),
    ])
    let runtime = try experimentalRuntime(model, tools: [read, broken, obsolete, recovery])
    let stream = await runtime.events()
    let collector = Task { () -> [AgentPlan] in
      var plans: [AgentPlan] = []
      for await event in stream { if case .planCreated(let plan) = event { plans.append(plan) } }
      return plans
    }
    let response = try await runtime.run("Read the name and process it")
    await runtime.finishEvents()
    let plans = await collector.value
    #expect(response.text == "Recovered")
    #expect(plans.count == 2)
    #expect(plans.last?.steps.map(\.toolName) == ["read", "recover", nil])
    #expect(await read.executions.count == 1)
    #expect(await broken.executions.count == 1)
    #expect(await obsolete.executions.isEmpty)
    #expect(await recovery.executions.first?.string("name") == "Ada")
    let requests = await model.requests
    #expect(requests.count == 3)
    #expect(requests[1].messages.last?.content.contains("Source unavailable") == true)
    #expect(requests[1].messages.last?.content.contains("Ada") == true)
  }

  @Test func anUnexpectedEmptyResultIsPreservedForTheRevisedPlan() async throws {
    let facts = PlanFacts(value: .array([]), empty: true)
    let recover = MockTool(name: "recover")
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("read_facts")]),
      proposal([advancedStep("recover", ["conditions": .array([clause("step_1", "is_empty")])])]),
      .text("Fallback completed"),
    ])
    let response = try await experimentalRuntime(model, tools: [facts, recover]).run(
      "Find useful facts")
    #expect(response.text == "Fallback completed")
    #expect(await recover.executions.count == 1)
    #expect(await model.requests.count == 3)
  }

  @Test func aReplanBudgetExhaustionReturnsTheFinalToolFailure() async throws {
    let first = MockTool(
      name: "first",
      handler: { _ in
        throw AgentError.toolFailed(tool: "first", message: "Unavailable")
      })
    let second = MockTool(
      name: "second",
      handler: { _ in
        throw AgentError.toolFailed(tool: "second", message: "Still unavailable")
      })
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("first")]), proposal([advancedStep("second")]),
    ])
    let runtime = try experimentalRuntime(model, tools: [first, second])
    #expect(await failure(runtime) == .toolFailed(tool: "second", message: "Still unavailable"))
    #expect(await model.requests.count == 2)
    #expect(await first.executions.count == 1)
    #expect(await second.executions.count == 1)
  }

  @Test func aProtectedCompletedPrefixIsNotReexecutedDuringRecovery() async throws {
    let write = MockTool(name: "write", permission: .userConfirmation)
    let broken = MockTool(
      name: "broken",
      handler: { _ in
        throw AgentError.toolFailed(tool: "broken", message: "Unavailable")
      })
    let recover = MockTool(name: "recover")
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("write"), advancedStep("broken")]),
      proposal([advancedStep("recover")]), .text("Done"),
    ])
    _ = try await experimentalRuntime(
      model, tools: [write, broken, recover], gate: ApprovePlanTool()
    ).run("Write once and recover")
    #expect(await write.executions.count == 1)
    #expect(await recover.executions.count == 1)
    let revision = await model.requests[1]
    let offered = revision.tools.first?.schema.parameters["steps"]
    if case .array(of: .object(let schema)) = offered?.type {
      #expect(schema.parameters["tool"]?.allowedValues?.contains("write") == false)
    } else {
      Issue.record("Expected a closed revised tool catalog")
    }
  }

  @Test(arguments: [false, true])
  func aRevisionCannotReplayAnAttemptedProtectedTool(_ completed: Bool) async throws {
    let write = MockTool(
      name: "write", permission: .userConfirmation,
      handler: { _ in
        if !completed { throw AgentError.toolFailed(tool: "write", message: "Outcome uncertain") }
        return "Saved"
      })
    let broken = MockTool(
      name: "broken",
      handler: { _ in
        throw AgentError.toolFailed(tool: "broken", message: "Unavailable")
      })
    let initial =
      completed ? [advancedStep("write"), advancedStep("broken")] : [advancedStep("write")]
    let model = ScriptedModelProvider(responses: [
      proposal(initial), proposal([advancedStep("write")]),
    ])
    let runtime = try experimentalRuntime(
      model, tools: [write, broken], gate: ApprovePlanTool(),
      planner: ModelDrivenPlanner(maxRepairs: 0))
    guard case .invalidArguments = await failure(runtime) else {
      Issue.record("Expected protected-tool replay rejection")
      return
    }
    #expect(await write.executions.count == 1)
    #expect(await model.requests.count == 2)
  }

  @Test func aRevisedProtectedToolStillRequiresPermission() async throws {
    let broken = MockTool(
      name: "broken",
      handler: { _ in
        throw AgentError.toolFailed(tool: "broken", message: "Unavailable")
      })
    let write = MockTool(name: "write", permission: .userConfirmation)
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("broken")]), proposal([advancedStep("write")]),
    ])
    let runtime = try experimentalRuntime(model, tools: [broken, write], gate: DenyPlanTool())
    #expect(await failure(runtime) == .permissionDenied(tool: "write"))
    #expect(await write.executions.isEmpty)
    #expect(await model.requests.count == 2)
  }

  @Test(arguments: [false, true])
  func replanningIsBoundedByModelDeadlinesAndCancellation(_ cancel: Bool) async throws {
    let tool = MockTool(
      name: "broken",
      handler: { _ in
        throw AgentError.toolFailed(tool: "broken", message: "Unavailable")
      })
    let model = ScriptedModelProvider([.respond(proposal([advancedStep("broken")])), .hang])
    let limits = ExecutionLimits(maxModelCallDuration: cancel ? .seconds(30) : .milliseconds(20))
    let runtime = try experimentalRuntime(model, tools: [tool], limits: limits)
    let run = Task { await failure(runtime) }
    if cancel {
      while await model.requests.count < 2 { await Task.yield() }
      run.cancel()
    }
    #expect(await run.value == (cancel ? .cancelled : .executionTimeout(.modelCall)))
    #expect(await tool.executions.count == 1)
  }

  @Test func refusalDuringARevisionIsTerminal() async throws {
    let tool = MockTool(
      name: "broken",
      handler: { _ in
        throw AgentError.toolFailed(tool: "broken", message: "Unavailable")
      })
    let refusal = GuardrailRefusal(explanation: "Cannot revise this request")
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("broken")]), .refused(refusal),
    ])
    let runtime = try experimentalRuntime(model, tools: [tool])
    #expect(await failure(runtime) == .guardrailRefusal(refusal))
    #expect(await model.requests.count == 2)
  }

  @Test func revisedPlanPublicationConsumesAnIteration() async throws {
    let tool = MockTool(
      name: "broken",
      handler: { _ in
        throw AgentError.toolFailed(tool: "broken", message: "Unavailable")
      })
    let recovery = MockTool(name: "recover")
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("broken")]), proposal([advancedStep("recover")]),
    ])
    let runtime = try experimentalRuntime(
      model, tools: [tool, recovery], limits: ExecutionLimits(maxIterations: 2))
    #expect(await failure(runtime) == .maximumIterationsReached(limit: 2))
    #expect(await recovery.executions.isEmpty)
    #expect(await model.requests.count == 2)
  }
}

extension ModelDrivenPlannerTests {
  @Test func aRevisionCannotExpandTheConfiguredRemainingStepBudget() async throws {
    let read = MockTool(name: "read")
    let broken = MockTool(
      name: "broken",
      handler: { _ in
        throw AgentError.toolFailed(tool: "broken", message: "Unavailable")
      })
    let unused = MockTool(name: "unused")
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("read"), advancedStep("broken")]),
      proposal([advancedStep("unused"), advancedStep("unused")]),
    ])
    let runtime = try experimentalRuntime(
      model, tools: [read, broken, unused], planner: ModelDrivenPlanner(maxSteps: 2))
    guard case .invalidArguments = await failure(runtime) else {
      Issue.record("Expected revision step-budget rejection")
      return
    }
    #expect(await read.executions.count == 1)
    #expect(await unused.executions.isEmpty)
  }

  @Test func revisionsCannotResetTheRuntimeToolCallBudget() async throws {
    let broken = MockTool(
      name: "broken",
      handler: { _ in
        throw AgentError.toolFailed(tool: "broken", message: "Unavailable")
      })
    let recovery = MockTool(name: "recover")
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("broken")]), proposal([advancedStep("recover")]),
    ])
    let runtime = try experimentalRuntime(
      model, tools: [broken, recovery], limits: ExecutionLimits(maxToolCalls: 1))
    #expect(await failure(runtime) == .maximumToolCallsReached(limit: 1))
    #expect(await recovery.executions.isEmpty)
    #expect(await model.requests.count == 2)
  }

  @Test func aSharedPlannerHasAnIndependentRevisionBudgetForEachRun() async throws {
    let broken = MockTool(
      name: "broken",
      handler: { _ in
        throw AgentError.toolFailed(tool: "broken", message: "Unavailable")
      })
    let planner = ModelDrivenPlanner()
    let model = ScriptedModelProvider(responses: [
      proposal([advancedStep("broken")]), proposal([]), .text("First recovered"),
      proposal([advancedStep("broken")]), proposal([]), .text("Second recovered"),
    ])
    let runtime = try experimentalRuntime(model, tools: [broken], planner: planner)
    #expect(try await runtime.run("First request").text == "First recovered")
    #expect(try await runtime.run("Second request").text == "Second recovered")
    #expect(await broken.executions.count == 2)
    #expect(await model.requests.count == 6)
  }
}
