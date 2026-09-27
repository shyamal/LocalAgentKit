import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

// MARK: - Test harness

/// Stands in for `AgentRuntime` (M1-RT-01): asks the planner what to do, runs calls through the
/// real `ToolExecutor`, and reports outcomes back.
private struct Driver {
  var planner: StateMachinePlanner
  var tools: [MockTool]
  var model: ScriptedModelProvider
  var gate: (any PermissionGate)?
  var maxSteps = 20

  struct Outcome {
    var decision: PlannerDecision?
    var error: AgentError?
    var context: AgentContext
    var plan: AgentPlan?
  }

  func run(_ goal: String, conversation: [ModelMessage] = []) async -> Outcome {
    var context = AgentContext(
      goal: goal, now: Date(timeIntervalSince1970: 1_790_000_000),
      timeZone: TimeZone(identifier: "UTC")!, conversation: conversation)
    let descriptors = tools.map { ToolDescriptor($0) }
    let executor = ToolExecutor(
      source: StaticToolSource(tools), gate: gate, events: EventBus())
    var plan: AgentPlan?
    do {
      plan = try await planner.plan(context: &context, tools: descriptors, model: model)
      for _ in 0..<maxSteps {
        let decision = try await planner.next(
          context: &context, tools: descriptors, model: model)
        guard case .callTool(let call) = decision else {
          return Outcome(decision: decision, error: nil, context: context, plan: plan)
        }
        do {
          let observation = try await executor.execute(call)
          _ = try planner.observe(observation, context: &context)
        } catch let error as AgentError {
          _ = try planner.handleFailure(error, context: &context)
        }
      }
      return Outcome(
        decision: nil, error: .maximumIterationsReached(limit: maxSteps), context: context,
        plan: plan)
    } catch let error as AgentError {
      return Outcome(decision: nil, error: error, context: context, plan: plan)
    } catch {
      return Outcome(decision: nil, error: .cancelled, context: context, plan: plan)
    }
  }
}

private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) -> ModelResponse {
  .toolCall(ToolCall(id: "m", name: name, arguments: ToolArguments(arguments)))
}

private func choose(_ workflow: String) -> ModelResponse {
  call("choose_workflow", ["workflow": .string(workflow)])
}

private func stringSchema(_ names: String..., required: Bool = true) -> ToolSchema {
  ToolSchema(
    parameters: Dictionary(
      uniqueKeysWithValues: names.map { ($0, ToolParameter(.string, description: $0)) }),
    required: required ? Set(names) : [])
}

private func text(_ value: String) -> MockTool.Handler { { _ in value } }

private func completed(_ outcome: Driver.Outcome) -> String? {
  if case .complete(let text) = outcome.decision { text } else { nil }
}

// MARK: - Workflows

@Suite struct WorkflowExecutionTests {
  private func prepWorkflow() -> Workflow {
    Workflow(
      name: "meeting_prep", description: "Prepare for a meeting",
      steps: [
        .tool(
          "find", "Find the meeting", "search_events", ["day": .model(hint: "The day, YYYY-MM-DD")]),
        .tool(
          "notes", "Find related notes", "search_notes",
          ["query": .binding("find.title")]),
        .respond(instruction: "Summarize the meeting and its notes."),
      ])
  }

  private func prepTools(events: String = "{}") -> [MockTool] {
    [
      MockTool(
        name: "search_events", schema: stringSchema("day"), permission: .readOnly,
        handler: { _ in "Budget review at 3pm" }),
      MockTool(
        name: "search_notes", schema: stringSchema("query"), permission: .readOnly,
        handler: { args in "Notes about \(args.string("query") ?? "?")" }),
    ]
  }

  @Test func runsStepsInOrderAndCarriesValuesInCode() async throws {
    let tools = [
      MockTool(
        name: "search_events", schema: stringSchema("day"), permission: .readOnly,
        handler: { _ in "ignored" }),
      MockTool(name: "search_notes", schema: stringSchema("query"), permission: .readOnly),
    ]
    // The event tool returns structured data through a custom result? MockTool returns text only,
    // so bind the whole text: use a workflow that reads `find` directly.
    let workflow = Workflow(
      name: "prep", description: "Prep",
      steps: [
        .tool("find", "Find", "search_events", ["day": .model(hint: "day")]),
        .tool("notes", "Notes", "search_notes", ["query": .binding("find")]),
        .respond(instruction: "Summarize."),
      ])
    let model = ScriptedModelProvider(responses: [
      choose("prep"),
      call("provide_search_events_arguments", ["day": "2026-09-22"]),
      .text("You have notes for it."),
    ])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: tools, model: model
    ).run("What do I need for tomorrow's meeting?")

    #expect(completed(outcome) == "You have notes for it.")
    #expect(await tools[0].executions == [ToolArguments(["day": "2026-09-22"])])
    // The second step's argument came from the first step's result, with no model involvement.
    #expect(await tools[1].executions == [ToolArguments(["query": "ignored"])])
    // Three model calls only: choose, one narrow extraction, the answer.
    #expect(await model.requests.count == 3)
    #expect(outcome.plan?.steps.map(\.id) == ["find", "notes", "respond"])
  }

  @Test func theExtractionQuestionShowsOnlyWhatCodeCannotSupply() async throws {
    let tools = [
      MockTool(
        name: "create_note", schema: stringSchema("title", "body"), permission: .userConfirmation)
    ]
    let workflow = Workflow(
      name: "note", description: "Save a note",
      steps: [
        .tool(
          "save", "Save", "create_note",
          ["title": .literal("Prep"), "body": .model(hint: "The note text")])
      ])
    let model = ScriptedModelProvider(responses: [
      choose("note"), call("provide_create_note_arguments", ["body": "hello"]),
    ])
    let gate = AlwaysApprove()
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: tools, model: model, gate: gate
    ).run("Save a note saying hello")
    #expect(outcome.error == nil)
    let request = await model.requests[1]
    let asked = try #require(request.tools.first)
    #expect(asked.schema.parameters.keys.sorted() == ["body"])
    #expect(asked.schema.parameters["body"]?.description == "The note text")
    #expect(await tools[0].executions == [ToolArguments(["title": "Prep", "body": "hello"])])
  }

  @Test func theQuestionCarriesTodaysDateAndRecentConversation() async throws {
    let tools = [
      MockTool(name: "search_events", schema: stringSchema("day"), permission: .readOnly)
    ]
    let workflow = Workflow(
      name: "w", description: "d",
      steps: [.tool("find", "Find", "search_events", ["day": .model(hint: "day")])])
    let model = ScriptedModelProvider(responses: [
      choose("w"), call("provide_search_events_arguments", ["day": "2026-09-22"]),
    ])
    _ = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: tools, model: model
    ).run(
      "And tomorrow?",
      conversation: [
        ModelMessage(role: .user, content: "What meetings do I have today?"),
        ModelMessage(role: .assistant, content: "Two meetings."),
      ])
    let extraction = await model.requests[1]
    let system = extraction.messages.first { $0.role == .system }?.content ?? ""
    let user = extraction.messages.first { $0.role == .user }?.content ?? ""
    #expect(system.hasPrefix("Today is Monday 2026-09-21, 14:13"))
    #expect(user.contains("What meetings do I have today?"))
    #expect(user.contains("Request: And tomorrow?"))
  }

  @Test func aStepWithNoModelSourcedArgumentsNeverAsksTheModel() async throws {
    let tools = [MockTool(name: "get_time", permission: .none)]
    let workflow = Workflow(
      name: "time", description: "Tell the time", steps: [.tool("t", "Time", "get_time")])
    let model = ScriptedModelProvider(responses: [choose("time")])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: tools, model: model
    ).run("What time is it?")
    #expect(completed(outcome) == "ok")
    #expect(await model.requests.count == 1)
  }

  @Test func respondStepPutsTheFoundFactsInThePrompt() async throws {
    let tools = [
      MockTool(name: "get_weather", permission: .readOnly, handler: text("Rain, 12 degrees"))
    ]
    let workflow = Workflow(
      name: "weather", description: "Weather",
      steps: [.tool("wx", "Weather", "get_weather"), .respond(instruction: "Say what to wear.")])
    let model = ScriptedModelProvider(responses: [choose("weather"), .text("Take a coat.")])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: tools, model: model
    ).run("What should I wear?")
    #expect(completed(outcome) == "Take a coat.")
    let prompt = try #require(await model.requests.last?.messages.last?.content)
    #expect(prompt.contains("wx: Rain, 12 degrees"))
    #expect(prompt.contains("Say what to wear."))
    #expect(await model.requests.last?.tools.isEmpty == true)
  }

  @Test func aWorkflowWithoutARespondStepCompletesWithTheLastResult() async throws {
    let tools = [MockTool(name: "get_time", permission: .none, handler: text("10:00"))]
    let workflow = Workflow(name: "t", description: "d", steps: [.tool("t", "T", "get_time")])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: tools,
      model: ScriptedModelProvider(responses: [choose("t")])
    ).run("time?")
    #expect(completed(outcome) == "10:00")
  }

  @Test func clarificationFromTheAnswerSuspendsForTheUser() async throws {
    let tools = [MockTool(name: "get_time", permission: .none)]
    let workflow = Workflow(
      name: "t", description: "d", steps: [.tool("t", "T", "get_time"), .respond(instruction: "x")])
    let model = ScriptedModelProvider(responses: [choose("t"), .clarification("Which time zone?")])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: tools, model: model
    ).run("time?")
    guard case .askUser(let question) = outcome.decision else {
      Issue.record("expected askUser")
      return
    }
    #expect(question == "Which time zone?")
  }
}

private struct AlwaysApprove: PermissionGate {
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision { .approved }
}
private struct AlwaysDeny: PermissionGate {
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision { .denied }
}

// MARK: - Guards

@Suite struct ConditionalGuardTests {
  /// The ms-10 shape: do the thing only if the saving is at least $10. The model did the
  /// forbidden action in 4–5 of 5 runs; here the condition is code.
  private func run(saving: String) async -> (Driver.Outcome, MockTool) {
    let calc = MockTool(name: "calculate", permission: .none, handler: text(saving))
    let switchPlan = MockTool(name: "switch_plan", permission: .none, handler: text("switched"))
    let workflow = Workflow(
      name: "compare", description: "Switch plans if it saves enough",
      steps: [
        .tool("saving", "Work out the saving", "calculate"),
        .tool(
          "switch", "Switch plans", "switch_plan",
          condition: .number("saving", .atLeast, 10)),
      ])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: [calc, switchPlan],
      model: ScriptedModelProvider(responses: [choose("compare")])
    ).run("Switch if it saves at least $10")
    return (outcome, switchPlan)
  }

  @Test func belowTheThresholdTheStepIsSkippedAndNeverRuns() async {
    let (outcome, tool) = await run(saving: "7")
    #expect(await tool.executions.isEmpty)
    #expect(outcome.context.skippedSteps == ["switch"])
    #expect(outcome.error == nil)
  }

  @Test func atTheThresholdItRuns() async {
    let (_, tool) = await run(saving: "10.00")
    #expect(await tool.executions.count == 1)
  }

  @Test func aNumberInsideTextIsNotGuessedAt() async {
    // "$12" is not a plain number; the guard is false rather than a crash or a guess.
    let (_, tool) = await run(saving: "You save about $12")
    #expect(await tool.executions.isEmpty)
  }

  private func context(_ bindings: [String: JSONValue], empty: Set<String> = []) -> AgentContext {
    var context = AgentContext(goal: "g")
    for (name, value) in bindings { context.bind(name, value, isEmpty: empty.contains(name)) }
    return context
  }

  @Test func guardCases() {
    let ctx = context(
      [
        "n": .int(5), "s": "12.5", "list": [1, 2], "none": [], "text": "hi", "blank": "  ",
        "obj": ["a": ["b": 3]], "found": "x",
      ],
      empty: ["found"])
    #expect(Guard.always.evaluate(ctx))
    #expect(Guard.exists("n").evaluate(ctx))
    #expect(!Guard.exists("missing").evaluate(ctx))
    #expect(Guard.isEmpty("missing").evaluate(ctx))
    #expect(Guard.isEmpty("none").evaluate(ctx))
    #expect(Guard.isEmpty("blank").evaluate(ctx))
    #expect(Guard.isEmpty("found").evaluate(ctx))  // a tool that found nothing
    #expect(!Guard.isEmpty("list").evaluate(ctx))
    #expect(Guard.equals("text", "hi").evaluate(ctx))
    #expect(!Guard.equals("text", "no").evaluate(ctx))
    #expect(Guard.number("s", .greaterThan, 12).evaluate(ctx))
    #expect(Guard.number("n", .equalTo, 5).evaluate(ctx))
    #expect(Guard.number("n", .lessThan, 6).evaluate(ctx))
    #expect(Guard.number("n", .atMost, 5).evaluate(ctx))
    #expect(!Guard.number("missing", .atLeast, 0).evaluate(ctx))
    #expect(!Guard.number("text", .atLeast, 0).evaluate(ctx))
    #expect(Guard.number("obj.a.b", .equalTo, 3).evaluate(ctx))
    #expect(Guard.not(.exists("missing")).evaluate(ctx))
    #expect(Guard.all([.exists("n"), .exists("s")]).evaluate(ctx))
    #expect(!Guard.all([.exists("n"), .exists("missing")]).evaluate(ctx))
    #expect(Guard.any([.exists("missing"), .exists("n")]).evaluate(ctx))
    #expect(!Guard.any([]).evaluate(ctx))
    #expect(Guard.all([]).evaluate(ctx))
  }

  @Test func pathsResolveThroughObjectsAndArrays() {
    let ctx = context(["r": ["items": [["title": "A"], ["title": "B"]]]])
    #expect(ctx.value(for: "r.items.1.title") == "B")
    #expect(ctx.value(for: "r.items.9") == nil)
    #expect(ctx.value(for: "r.items.x") == nil)
    #expect(ctx.value(for: "r.items.0.title.deeper") == nil)
    #expect(ctx.value(for: "nope") == nil)
  }
}

// MARK: - Recovery, retries, denial

@Suite struct RecoveryTests {
  private func searchWorkflow(
    onEmpty: Recovery = .fail, alternative: Bool = true, onFailure: Recovery = .fail,
    retries: Int = 1
  ) -> Workflow {
    Workflow(
      name: "find", description: "Find things",
      steps: [
        .tool(
          "search", "Search notes", "search_notes", ["query": .literal("budget")],
          alternative: alternative
            ? ToolInvocation(tool: "search_documents", arguments: ["query": .literal("budget")])
            : nil,
          onEmpty: onEmpty, onFailure: onFailure, retries: retries)
      ])
  }

  private func emptyResult() -> MockTool.Handler { { _ in "" } }

  /// MockTool has no way to flag an empty result, so this tool does.
  private actor EmptyTool: AgentTool {
    nonisolated let name: String
    nonisolated let description = "Search"
    nonisolated let schema = stringSchema("query")
    nonisolated let permission = ToolPermission.readOnly
    nonisolated let isParallelSafe = true
    nonisolated let isCancellable = true
    private let found: Bool
    private(set) var runs = 0
    init(_ name: String, found: Bool) {
      self.name = name
      self.found = found
    }
    func execute(arguments: ToolArguments) async throws -> ToolResult {
      runs += 1
      return ToolResult(
        callID: "", toolName: name, text: found ? "found it" : "", isEmpty: !found)
    }
  }

  private func run(
    _ workflow: Workflow, tools: [any AgentTool], model: ScriptedModelProvider? = nil,
    gate: (any PermissionGate)? = nil
  ) async -> Driver.Outcome {
    let descriptors = tools.map { ToolDescriptor($0) }
    var context = AgentContext(goal: "find budget")
    let planner = StateMachinePlanner(workflows: [workflow])
    let executor = ToolExecutor(source: StaticToolSource(tools), gate: gate, events: EventBus())
    let model = model ?? ScriptedModelProvider(responses: [choose("find"), .text("done")])
    do {
      _ = try await planner.plan(context: &context, tools: descriptors, model: model)
      for _ in 0..<20 {
        let decision = try await planner.next(context: &context, tools: descriptors, model: model)
        guard case .callTool(let call) = decision else {
          return Driver.Outcome(decision: decision, error: nil, context: context, plan: nil)
        }
        do {
          _ = try planner.observe(try await executor.execute(call), context: &context)
        } catch let error as AgentError {
          _ = try planner.handleFailure(error, context: &context)
        }
      }
    } catch let error as AgentError {
      return Driver.Outcome(decision: nil, error: error, context: context, plan: nil)
    } catch {}
    return Driver.Outcome(decision: nil, error: .cancelled, context: context, plan: nil)
  }

  @Test func anEmptyResultTakesTheDeclaredAlternative() async {
    let notes = EmptyTool("search_notes", found: false)
    let docs = EmptyTool("search_documents", found: true)
    let outcome = await run(searchWorkflow(), tools: [notes, docs])
    #expect(outcome.error == nil)
    #expect(await notes.runs == 1)
    #expect(await docs.runs == 1)
    // The alternative's result is bound under the primary step's name.
    #expect(outcome.context.value(for: "search") == "found it")
    #expect(!outcome.context.emptyBindings.contains("search"))
  }

  @Test func aFoundResultNeverTouchesTheAlternative() async {
    let notes = EmptyTool("search_notes", found: true)
    let docs = EmptyTool("search_documents", found: true)
    _ = await run(searchWorkflow(), tools: [notes, docs])
    #expect(await docs.runs == 0)
  }

  @Test func emptyWithNoAlternativeIsATypedError() async {
    let notes = EmptyTool("search_notes", found: false)
    let outcome = await run(
      searchWorkflow(alternative: false),
      tools: [notes, EmptyTool("search_documents", found: true)])
    guard case .toolFailed(let tool, let message)? = outcome.error else {
      Issue.record("expected toolFailed, got \(String(describing: outcome.error))")
      return
    }
    #expect(tool == "search_notes")
    #expect(message.contains("no alternative"))
  }

  @Test func bothEmptyIsATypedErrorAndTheAlternativeRunsOnce() async {
    let notes = EmptyTool("search_notes", found: false)
    let docs = EmptyTool("search_documents", found: false)
    let outcome = await run(searchWorkflow(), tools: [notes, docs])
    #expect(outcome.error != nil)
    #expect(await docs.runs == 1)
  }

  @Test func skipBindsNothingAndCarriesOn() async {
    let outcome = await run(
      searchWorkflow(onEmpty: .skip, alternative: false),
      tools: [EmptyTool("search_notes", found: false), EmptyTool("search_documents", found: true)])
    #expect(outcome.error == nil)
    #expect(outcome.context.emptyBindings.contains("search"))
  }

  @Test func aFailingToolIsRetriedThenSucceeds() async {
    let attempts = Counter()
    let tool = MockTool(
      name: "search_notes", schema: stringSchema("query"), permission: .readOnly,
      handler: { _ in
        if await attempts.next() == 1 { throw Flaky() }
        return "ok"
      })
    let outcome = await run(
      searchWorkflow(alternative: false), tools: [tool])
    #expect(outcome.error == nil)
    #expect(await tool.executions.count == 2)
  }

  @Test func retriesAreBounded() async {
    let tool = MockTool(
      name: "search_notes", schema: stringSchema("query"), permission: .readOnly,
      handler: { _ in throw Flaky() })
    let outcome = await run(searchWorkflow(alternative: false, retries: 2), tools: [tool])
    #expect(await tool.executions.count == 3)  // one attempt and two retries
    guard case .toolFailed? = outcome.error else {
      Issue.record("expected toolFailed")
      return
    }
  }

  @Test func afterRetriesTheAlternativeIsTried() async {
    let notes = MockTool(
      name: "search_notes", schema: stringSchema("query"), permission: .readOnly,
      handler: { _ in throw Flaky() })
    let docs = EmptyTool("search_documents", found: true)
    let outcome = await run(searchWorkflow(retries: 0), tools: [notes, docs])
    #expect(outcome.error == nil)
    #expect(await docs.runs == 1)
  }

  @Test func onFailureSkipCarriesOn() async {
    let tool = MockTool(
      name: "search_notes", schema: stringSchema("query"), permission: .readOnly,
      handler: { _ in throw Flaky() })
    let outcome = await run(
      searchWorkflow(alternative: false, onFailure: .skip, retries: 0), tools: [tool])
    #expect(outcome.error == nil)
  }

  /// Recovery must never route around a human's "no".
  @Test func aDeniedStepIsNeitherRetriedNorRoutedAround() async {
    let notes = MockTool(
      name: "search_notes", schema: stringSchema("query"), permission: .userConfirmation)
    let docs = MockTool(
      name: "search_documents", schema: stringSchema("query"), permission: .readOnly)
    let outcome = await run(
      searchWorkflow(onFailure: .skip, retries: 3), tools: [notes, docs], gate: AlwaysDeny())
    #expect(outcome.error == .permissionDenied(tool: "search_notes"))
    #expect(await notes.executions.isEmpty)
    #expect(await docs.executions.isEmpty)
  }

  private struct Flaky: Error {}
  private actor Counter {
    var value = 0
    func next() -> Int {
      value += 1
      return value
    }
  }
}

// MARK: - Open mode

@Suite struct OpenModeTests {
  private func choice(_ action: String) -> ModelResponse {
    call("choose_next_action", ["action": .string(action)])
  }

  @Test func noWorkflowsMeansEveryGoalRunsOpen() async throws {
    let events = MockTool(
      name: "read_calendar", schema: stringSchema("day"), permission: .readOnly,
      handler: text("Standup 9am"))
    let model = ScriptedModelProvider(responses: [
      choice("read_calendar"), call("provide_read_calendar_arguments", ["day": "2026-09-22"]),
      choice("finish"), .text("You have standup at 9."),
    ])
    let outcome = await Driver(planner: StateMachinePlanner(), tools: [events], model: model)
      .run("What meetings do I have tomorrow?")
    #expect(completed(outcome) == "You have standup at 9.")
    #expect(await events.executions == [ToolArguments(["day": "2026-09-22"])])
    #expect(outcome.plan?.steps.map(\.id) == ["open"])
    // The finish prompt saw what the tool returned.
    let prompt = try #require(await model.requests.last?.messages.last?.content)
    #expect(prompt.contains("Standup 9am"))
  }

  @Test func chooseNoneFallsThroughToOpen() async throws {
    let tool = MockTool(name: "get_time", permission: .none, handler: text("10:00"))
    let workflow = Workflow(
      name: "note", description: "Save notes", steps: [.tool("t", "T", "get_time")])
    let model = ScriptedModelProvider(responses: [
      choose("none"), choice("get_time"), choice("finish"), .text("It is 10:00."),
    ])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: [tool], model: model
    ).run("What time is it?")
    #expect(completed(outcome) == "It is 10:00.")
    #expect(outcome.context.workflowName == nil)
  }

  @Test func theModelCanAnswerWithoutAnyTool() async throws {
    let tool = MockTool(name: "get_time", permission: .none)
    let model = ScriptedModelProvider(responses: [choice("finish"), .text("Hello!")])
    let outcome = await Driver(planner: StateMachinePlanner(), tools: [tool], model: model)
      .run("Hi")
    #expect(completed(outcome) == "Hello!")
    #expect(await tool.executions.isEmpty)
  }

  /// Phase 0: the model created the same note twice in 22 of 50 iOS runs.
  @Test func anIdenticalSideEffectingCallIsNotMadeTwice() async throws {
    let note = MockTool(
      name: "create_note", schema: stringSchema("text"), permission: .userConfirmation)
    let args = call("provide_create_note_arguments", ["text": "hello"])
    let model = ScriptedModelProvider(responses: [
      choice("create_note"), args,
      choice("create_note"), args,  // the model asks for the same note again
      .text("Saved."),
    ])
    let outcome = await Driver(
      planner: StateMachinePlanner(), tools: [note], model: model, gate: AlwaysApprove()
    ).run("Save a note saying hello")
    #expect(await note.executions.count == 1)
    #expect(completed(outcome) == "Saved.")
  }

  @Test func aReadOnlyCallMayRepeat() async throws {
    let tool = MockTool(name: "get_time", permission: .none)
    let model = ScriptedModelProvider(responses: [
      choice("get_time"), choice("get_time"), choice("finish"), .text("ok"),
    ])
    _ = await Driver(planner: StateMachinePlanner(), tools: [tool], model: model).run("time twice")
    #expect(await tool.executions.count == 2)
  }

  @Test func aFailedToolIsReportedToTheNextChoiceThenRemoved() async throws {
    let flaky = MockTool(
      name: "read_calendar", schema: stringSchema("day"), permission: .readOnly,
      handler: { _ in throw AgentError.retrievalFailure("no access") })
    let arguments = call("provide_read_calendar_arguments", ["day": "2026-09-22"])
    let model = ScriptedModelProvider(responses: [
      choice("read_calendar"), arguments,
      choice("read_calendar"), arguments,
      choice("finish"), .text("I could not read the calendar."),
    ])
    let outcome = await Driver(planner: StateMachinePlanner(), tools: [flaky], model: model)
      .run("meetings?")
    // `AgentError`s from a tool pass through the executor unchanged, so this is not a tool
    // failure to recover from; it ends the run with that typed error.
    #expect(outcome.error == .retrievalFailure("no access"))
  }

  @Test func toolFailureNotesReachTheNextChoiceAndTwoFailuresRemoveTheTool() async throws {
    struct Boom: Error {}
    let flaky = MockTool(
      name: "read_calendar", schema: stringSchema("day"), permission: .readOnly,
      handler: { _ in throw Boom() })
    let arguments = call("provide_read_calendar_arguments", ["day": "2026-09-22"])
    let model = ScriptedModelProvider(responses: [
      choice("read_calendar"), arguments,
      choice("read_calendar"), arguments,
      choice("finish"), .text("Could not read it."),
    ])
    let outcome = await Driver(planner: StateMachinePlanner(), tools: [flaky], model: model)
      .run("meetings?")
    #expect(completed(outcome) == "Could not read it.")
    let requests = await model.requests
    // Second choice: told the first attempt failed. Third: the tool is no longer offered.
    #expect(requests[2].messages.last?.content.contains("read_calendar failed") == true)
    let thirdOptions = requests[4].tools.first?.schema.parameters["action"]?.allowedValues
    #expect(thirdOptions == ["finish"])
  }
}

// MARK: - Model answers

@Suite struct ModelAnswerTests {
  private let workflow = Workflow(
    name: "time", description: "Tell the time", steps: [.tool("t", "T", "get_time")])
  private let tool = MockTool(name: "get_time", permission: .none)

  @Test func aBadChoiceIsRepairedWithFeedback() async throws {
    let model = ScriptedModelProvider(responses: [choose("timee"), choose("time")])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: [tool], model: model
    ).run("time?")
    #expect(outcome.context.workflowName == "time")
    let feedback = await model.requests[1].messages.last?.content ?? ""
    #expect(feedback.contains("workflow must be one of: time, none"))
  }

  @Test func aPlainTextExactChoiceIsAccepted() async throws {
    let model = ScriptedModelProvider(responses: [.text("time.")])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: [tool], model: model
    ).run("time?")
    #expect(outcome.context.workflowName == "time")
    #expect(await model.requests.count == 1)
  }

  @Test func chattyTextIsNotGuessedAt() async throws {
    let model = ScriptedModelProvider(responses: [
      .text("I think the time workflow"), .text("still chatting"), .text("nope"),
    ])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: [tool], model: model
    ).run("time?")
    guard case .invalidArguments? = outcome.error else {
      Issue.record("expected invalidArguments, got \(String(describing: outcome.error))")
      return
    }
  }

  @Test func aRefusalIsTerminalAndNeverRetried() async throws {
    let refusal = GuardrailRefusal(explanation: "no")
    let model = ScriptedModelProvider(responses: [.refused(refusal), choose("time")])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: [tool], model: model
    ).run("time?")
    #expect(outcome.error == .guardrailRefusal(refusal))
    #expect(await model.remainingSteps == 1)
  }

  @Test func aRefusedAnswerIsTerminalToo() async throws {
    let refusal = GuardrailRefusal()
    let workflow = Workflow(
      name: "w", description: "d", steps: [.tool("t", "T", "get_time"), .respond(instruction: "x")])
    let model = ScriptedModelProvider(responses: [choose("w"), .refused(refusal)])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: [tool], model: model
    ).run("time?")
    #expect(outcome.error == .guardrailRefusal(refusal))
  }

  @Test func anEmptyAnswerIsATypedError() async throws {
    let workflow = Workflow(
      name: "w", description: "d", steps: [.tool("t", "T", "get_time"), .respond(instruction: "x")])
    let model = ScriptedModelProvider(responses: [choose("w"), .text("   ")])
    let outcome = await Driver(
      planner: StateMachinePlanner(workflows: [workflow]), tools: [tool], model: model
    ).run("time?")
    guard case .modelUnavailable? = outcome.error else {
      Issue.record("expected modelUnavailable")
      return
    }
  }

  @Test func nextBeforePlanIsAnError() async {
    var context = AgentContext(goal: "g")
    await #expect(throws: AgentError.self) {
      _ = try await StateMachinePlanner().next(
        context: &context, tools: [], model: ScriptedModelProvider([]))
    }
  }
}

// MARK: - Validation

@Suite struct WorkflowValidationTests {
  private let search = ToolDescriptor(
    MockTool(name: "search_notes", schema: stringSchema("query"), permission: .readOnly))

  private func problems(_ steps: [WorkflowStep]) -> [String] {
    Workflow(name: "w", description: "d", steps: steps).problems(against: [search])
  }

  @Test func aSoundWorkflowHasNoProblems() {
    #expect(
      problems([
        .tool("a", "A", "search_notes", ["query": .literal("x")]),
        .tool("b", "B", "search_notes", ["query": .binding("a")]),
        .respond(instruction: "x"),
      ]).isEmpty)
  }

  @Test func unknownToolsParametersAndMissingSourcesAreFound() {
    #expect(problems([.tool("a", "A", "nope")]).contains { $0.contains("unknown tool nope") })
    #expect(
      problems([.tool("a", "A", "search_notes", ["query": .literal("x"), "extra": .literal("y")])])
        .contains { $0.contains("no parameter extra") })
    #expect(problems([.tool("a", "A", "search_notes")]).contains { $0.contains("no source") })
  }

  @Test func bindingsMustPointBackwards() {
    let found = problems([
      .tool("a", "A", "search_notes", ["query": .binding("later")]),
      .tool("later", "B", "search_notes", ["query": .literal("x")]),
    ])
    #expect(found.contains { $0.contains("no earlier step binds") })
  }

  @Test func structureIsChecked() {
    #expect(problems([]).contains("no steps"))
    #expect(
      problems([
        .tool("a", "A", "search_notes", ["query": .literal("x")]),
        .tool("a", "B", "search_notes", ["query": .literal("x")]),
      ]).contains { $0.contains("duplicate step id a") })
    #expect(
      problems([
        .respond(instruction: "x"),
        .tool("a", "A", "search_notes", ["query": .literal("x")]),
      ]).contains { $0.contains("respond must be last") })
  }

  @Test func alternativesAreChecked() {
    let step = WorkflowStep.tool(
      "a", "A", "search_notes", ["query": .literal("x")],
      alternative: ToolInvocation(tool: "ghost"))
    #expect(problems([step]).contains { $0.contains("unknown tool ghost") })
  }

  @Test func planRefusesAnUnrunnableWorkflowUpFront() async {
    var context = AgentContext(goal: "g")
    let planner = StateMachinePlanner(
      workflows: [Workflow(name: "w", description: "d", steps: [.tool("a", "A", "ghost")])])
    await #expect(throws: AgentError.self) {
      _ = try await planner.plan(
        context: &context, tools: [self.search], model: ScriptedModelProvider([]))
    }
  }
}
