import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

private actor BatchHold {
  var entered: [Int] = []
  var active = 0
  var maximum = 0
  var cancelled = 0
  var releases: [Int: AsyncStream<Void>.Continuation] = [:]
  var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
  func pause(_ index: Int) async throws -> String {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    releases[index] = continuation
    entered.append(index)
    active += 1
    maximum = max(maximum, active)
    let reached = waiters.filter { entered.count >= $0.0 }
    waiters.removeAll { entered.count >= $0.0 }
    for (_, waiter) in reached { waiter.resume() }
    for await _ in stream {}
    active -= 1
    releases.removeValue(forKey: index)
    if Task.isCancelled {
      cancelled += 1
      throw CancellationError()
    }
    return "result_\(index)"
  }
  func waitFor(_ count: Int) async {
    if entered.count < count { await withCheckedContinuation { waiters.append((count, $0)) } }
  }
  func release(_ index: Int) { releases[index]?.finish() }
  func releaseAll() { for value in releases.values { value.finish() } }
}

private struct BatchPlanner: AgentPlanner {
  let calls: [ToolCall]
  func plan(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    -> AgentPlan
  {
    AgentPlan(
      steps: calls.enumerated().map {
        PlanStep(id: "\($0.offset)", summary: $0.element.name, toolName: $0.element.name)
      })
  }
  func next(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    -> PlannerDecision
  {
    if context.observations.isEmpty { return .callTools(calls) }
    return .complete(context.observations.map { $0.result.text }.joined(separator: ","))
  }
  func observe(_ observation: ToolObservation, context: inout AgentContext) -> PlanRevision {
    context.observations.append(observation)
    context.bind(observation.call.name, .string(observation.result.text), isEmpty: false)
    return .continue
  }
  func handleFailure(_ error: AgentError, context: inout AgentContext) throws -> PlanRevision {
    throw error
  }
}

private actor SecondDenial: PermissionGate {
  var names: [String] = []
  func decide(for call: ToolCall, tool: ToolDescriptor) -> PermissionDecision {
    names.append(call.name)
    return names.count == 1 ? .approved : .denied
  }
}

private func parallelRuntime(
  _ tools: [any AgentTool], calls: [ToolCall], limits: ExecutionLimits = .default
) throws -> AgentRuntime {
  try AgentRuntime(
    configuration: AgentConfiguration(model: MockModelProvider(), limits: limits),
    tools: StaticToolSource(tools), planner: BatchPlanner(calls: calls))
}

@Suite struct ParallelToolTests {
  @Test func overlapIsBoundedAndResultsRetainSubmissionOrder() async throws {
    let hold = BatchHold()
    let tools = (0..<5).map { index in
      MockTool(name: "tool_\(index)", handler: { _ in try await hold.pause(index) })
    }
    let executor = ToolExecutor(source: StaticToolSource(tools), events: EventBus())
    let calls = tools.enumerated().map { ToolCall(id: "\($0.offset)", name: $0.element.name) }
    let task = Task { try await executor.executeBatch(calls) }
    await hold.waitFor(4)
    #expect(await hold.entered.count == 4)
    #expect(await hold.maximum == 4)
    await hold.release(3)
    await hold.waitFor(5)
    #expect(await hold.maximum == 4)
    await hold.releaseAll()
    let results = try await task.value
    #expect(results.map(\.call.id) == calls.map(\.id))
    #expect(results.map(\.result.text) == (0..<5).map { "result_\($0)" })
  }

  @Test func oneUnsafeToolSerializesTheWholeBatch() async throws {
    let hold = BatchHold()
    let first = MockTool(name: "first", handler: { _ in try await hold.pause(0) })
    let second = MockTool(
      name: "second", isParallelSafe: false, handler: { _ in try await hold.pause(1) })
    let executor = ToolExecutor(source: StaticToolSource([first, second]), events: EventBus())
    let task = Task {
      try await executor.executeBatch([
        ToolCall(id: "a", name: "first"), ToolCall(id: "b", name: "second"),
      ])
    }
    await hold.waitFor(1)
    #expect(await hold.entered == [0])
    await hold.release(0)
    await hold.waitFor(2)
    #expect(await hold.maximum == 1)
    await hold.release(1)
    #expect(try await task.value.count == 2)
  }

  @Test func allPermissionsAreResolvedBeforeAnyExecution() async throws {
    let first = MockTool(name: "first", permission: .userConfirmation)
    let second = MockTool(name: "second", permission: .sensitive)
    let gate = SecondDenial()
    let executor = ToolExecutor(
      source: StaticToolSource([first, second]), gate: gate, events: EventBus())
    await #expect(throws: AgentError.permissionDenied(tool: "second")) {
      try await executor.executeBatch([
        ToolCall(id: "a", name: "first"), ToolCall(id: "b", name: "second"),
      ])
    }
    #expect(await gate.names == ["first", "second"])
    #expect(await first.executions.isEmpty)
    #expect(await second.executions.isEmpty)
  }

  @Test(arguments: ["schema", "missing", "duplicate", "empty"])
  func malformedBatchCannotExecuteAPrefix(_ kind: String) async throws {
    let first = MockTool(name: "first")
    let second = MockTool(
      name: "second",
      schema: ToolSchema(
        parameters: ["x": ToolParameter(.integer, description: "Value")], required: ["x"]))
    let executor = ToolExecutor(source: StaticToolSource([first, second]), events: EventBus())
    let a = ToolCall(id: "a", name: "first")
    let calls: [ToolCall]
    switch kind {
    case "empty": calls = []
    case "duplicate": calls = [a, a]
    case "missing": calls = [a, ToolCall(id: "b", name: "unknown")]
    default: calls = [a, ToolCall(id: "b", name: "second")]
    }
    await #expect(throws: AgentError.self) { try await executor.executeBatch(calls) }
    #expect(await first.executions.isEmpty)
    #expect(await second.executions.isEmpty)
  }

  @Test func failureCancelsAnActiveSiblingWithoutPublishingItsLateResult() async throws {
    let hold = BatchHold()
    let first = MockTool(name: "waiting", handler: { _ in try await hold.pause(0) })
    let second = MockTool(
      name: "failing",
      handler: { _ in
        await hold.waitFor(1)
        throw AgentError.toolFailed(tool: "failing", message: "Fixture failure")
      })
    let bus = EventBus()
    let stream = await bus.subscribe()
    let executor = ToolExecutor(source: StaticToolSource([first, second]), events: bus)
    await #expect(throws: AgentError.toolFailed(tool: "failing", message: "Fixture failure")) {
      try await executor.executeBatch([
        ToolCall(id: "a", name: "waiting"), ToolCall(id: "b", name: "failing"),
      ])
    }
    #expect(await hold.cancelled == 1)
    await bus.finish()
    var completed = 0
    for await event in stream { if case .toolCompleted = event { completed += 1 } }
    #expect(completed == 0)
  }

  @Test func cancellationReachesAllActiveMembers() async throws {
    let hold = BatchHold()
    let tools = (0..<2).map { index in
      MockTool(name: "tool_\(index)", handler: { _ in try await hold.pause(index) })
    }
    let executor = ToolExecutor(source: StaticToolSource(tools), events: EventBus())
    let task = Task {
      try await executor.executeBatch(
        tools.enumerated().map { ToolCall(id: "\($0.offset)", name: $0.element.name) })
    }
    await hold.waitFor(2)
    task.cancel()
    await #expect(throws: AgentError.cancelled) { try await task.value }
    #expect(await hold.cancelled == 2)
  }

  @Test func runtimeObservesInOrderAndScopesDuplicatePlannerIDs() async throws {
    let hold = BatchHold()
    let first = MockTool(name: "first", handler: { _ in try await hold.pause(0) })
    let second = MockTool(name: "second", handler: { _ in try await hold.pause(1) })
    let runtime = try parallelRuntime(
      [first, second],
      calls: [ToolCall(id: "same", name: "first"), ToolCall(id: "same", name: "second")])
    let stream = await runtime.events()
    let run = Task { try await runtime.run("Run independent reads") }
    await hold.waitFor(2)
    await hold.release(1)
    await hold.release(0)
    let response = try await run.value
    #expect(response.text == "result_0,result_1")
    #expect(response.toolCallCount == 2 && response.iterations == 2)
    await runtime.finishEvents()
    var ids: [String] = []
    for await event in stream { if case .toolStarted(let call) = event { ids.append(call.id) } }
    #expect(Set(ids).count == 2)
    #expect(ids.allSatisfy { $0.hasSuffix(":same") })
    #expect(await runtime.workingMemory().value(for: "first") == .string("result_0"))
  }

  @Test func wholeBatchAdmissionRespectsTheToolCallBudget() async throws {
    let tool = MockTool(name: "read")
    let runtime = try parallelRuntime(
      [tool], calls: [ToolCall(id: "a", name: "read"), ToolCall(id: "b", name: "read")],
      limits: ExecutionLimits(maxToolCalls: 1))
    await #expect(throws: AgentError.maximumToolCallsReached(limit: 1)) {
      try await runtime.run("Read twice")
    }
    #expect(await tool.executions.isEmpty)
  }

  @Test func batchingCannotBypassExistingLoopProtection() async throws {
    let tool = MockTool(name: "read")
    let runtime = try parallelRuntime(
      [tool], calls: (0..<3).map { ToolCall(id: "\($0)", name: "read") })
    await #expect(throws: AgentError.loopDetected(tool: "read")) {
      try await runtime.run("Repeat the same read")
    }
    #expect(await tool.executions.isEmpty)
  }
}

private actor ChangingBatchSource: ToolSource {
  let original = MockTool(name: "read", handler: { _ in "original" })
  let replacement = MockTool(name: "read", permission: .sensitive, isParallelSafe: false)
  var lookups = 0
  func tool(named name: String) -> (any AgentTool)? {
    lookups += 1
    return lookups == 1 ? original : replacement
  }
  func descriptors() -> [ToolDescriptor] { [ToolDescriptor(original)] }
}

private actor LateBatchWrite {
  var entered = false
  var observer: CheckedContinuation<Void, Never>?
  var release: CheckedContinuation<Void, Never>?
  func perform() async -> String {
    await withCheckedContinuation { continuation in
      release = continuation
      entered = true
      observer?.resume()
      observer = nil
    }
    return "saved"
  }
  func wait() async { if !entered { await withCheckedContinuation { observer = $0 } } }
  func finish() {
    release?.resume()
    release = nil
  }
}

extension ParallelToolTests {
  @Test func aDynamicSourceIsResolvedOnlyOncePerBatchMember() async throws {
    let source = ChangingBatchSource()
    let executor = ToolExecutor(source: source, events: EventBus())
    let results = try await executor.executeBatch([ToolCall(id: "a", name: "read")])
    #expect(results.first?.result.text == "original")
    #expect(await source.lookups == 1)
    #expect(await source.replacement.executions.isEmpty)
  }

  @Test func completedConfirmedWorkIsAuditedEvenWhenCancellationSuppressesItsResult() async throws {
    let write = LateBatchWrite()
    let tool = MockTool(
      name: "write", permission: .sensitive, isCancellable: false,
      handler: { _ in
        await write.perform()
      })
    let audit = AuditLogger()
    let bus = EventBus()
    let stream = await bus.subscribe()
    let executor = ToolExecutor(
      source: StaticToolSource([tool]), gate: SecondDenial(), events: bus, auditLogger: audit)
    let run = Task { try await executor.executeBatch([ToolCall(id: "write", name: "write")]) }
    await write.wait()
    run.cancel()
    await write.finish()
    await #expect(throws: AgentError.cancelled) { try await run.value }
    #expect(await audit.allEntries().count == 1)
    await bus.finish()
    var completed = 0
    for await event in stream { if case .toolCompleted = event { completed += 1 } }
    #expect(completed == 0)
  }

  @Test func batchMembersRetainTheRunDeadline() async throws {
    let first = MockTool(
      name: "first",
      handler: { _ in
        try await Task.sleep(for: .seconds(60))
        return "late"
      })
    let second = MockTool(
      name: "second",
      handler: { _ in
        try await Task.sleep(for: .seconds(60))
        return "late"
      })
    let executor = ToolExecutor(
      source: StaticToolSource([first, second]), events: EventBus(),
      remainingTime: { .milliseconds(20) })
    await #expect(throws: AgentError.executionTimeout(.run)) {
      try await executor.executeBatch([
        ToolCall(id: "a", name: "first"), ToolCall(id: "b", name: "second"),
      ])
    }
  }

  @Test func theRuntimeRequestsBatchConfirmationsOneAtATime() async throws {
    let first = MockTool(name: "first", permission: .userConfirmation)
    let second = MockTool(name: "second", permission: .sensitive)
    let runtime = try parallelRuntime(
      [first, second],
      calls: [ToolCall(id: "same", name: "first"), ToolCall(id: "same", name: "second")])
    let stream = await runtime.events()
    let run = Task { try await runtime.run("Run two independent protected operations") }
    var permissions: [String] = []
    var starts = 0
    for await event in stream {
      if case .permissionRequired(let call) = event {
        #expect(starts == 0)
        #expect(await first.executions.isEmpty)
        #expect(await second.executions.isEmpty)
        permissions.append(call.id)
        #expect(await runtime.resolvePermission(callID: call.id, approved: true))
      }
      if case .toolStarted = event {
        starts += 1
        #expect(permissions.count == 2)
      }
      if case .completed = event { break }
      if case .error = event { break }
    }
    let response = try await run.value
    await runtime.finishEvents()
    #expect(response.toolCallCount == 2 && starts == 2)
    #expect(Set(permissions).count == 2)
  }
}

extension ParallelToolTests {
  @Test func runtimeCancellationLeavesNoBatchFactsOrCompletion() async throws {
    let hold = BatchHold()
    let tools = (0..<2).map { index in
      MockTool(name: "tool_\(index)", handler: { _ in try await hold.pause(index) })
    }
    let runtime = try parallelRuntime(
      tools, calls: tools.map { ToolCall(id: "same", name: $0.name) })
    let stream = await runtime.events()
    let run = Task { try await runtime.run("Run independent reads") }
    await hold.waitFor(2)
    await runtime.cancelCurrentRun()
    await #expect(throws: AgentError.cancelled) { try await run.value }
    #expect(await runtime.workingMemory().values.isEmpty)
    // Deadline wrappers can return before cooperative underlying work finishes unwinding.
    let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await hold.cancelled < 2, ContinuousClock.now < cleanupDeadline { await Task.yield() }
    #expect(await hold.cancelled == 2)
    await runtime.finishEvents()
    var completed = false
    for await event in stream { if case .completed = event { completed = true } }
    #expect(!completed)
  }

  @Test func partialExecutionFailureDoesNotBecomeSuccessfulBatchFacts() async throws {
    let hold = BatchHold()
    let first = MockTool(name: "fast", handler: { _ in "Finished read" })
    let second = MockTool(
      name: "fail",
      handler: { _ in
        _ = try await hold.pause(0)
        throw AgentError.toolFailed(tool: "fail", message: "Fixture failure")
      })
    let runtime = try parallelRuntime(
      [first, second], calls: [ToolCall(id: "a", name: "fast"), ToolCall(id: "b", name: "fail")])
    let stream = await runtime.events()
    let run = Task { try await runtime.run("Run two independent reads") }
    await hold.waitFor(1)
    for await event in stream {
      if case .toolCompleted(let result) = event, result.toolName == "fast" {
        await hold.release(0)
        break
      }
    }
    await #expect(throws: AgentError.toolFailed(tool: "fail", message: "Fixture failure")) {
      try await run.value
    }
    #expect(await first.executions.count == 1)
    #expect(await runtime.workingMemory().values.isEmpty)
    await runtime.finishEvents()
  }
}

private actor BatchBudget {
  var expired = false
  func remaining() -> Duration { expired ? .zero : .seconds(30) }
  func expire() { expired = true }
}

extension ParallelToolTests {
  @Test func queuedNoncancellableWorkCannotStartAfterTheBudgetExpires() async throws {
    let hold = BatchHold()
    let budget = BatchBudget()
    let tools = (0..<5).map { index in
      MockTool(
        name: "tool_\(index)", isCancellable: false, handler: { _ in try await hold.pause(index) })
    }
    let executor = ToolExecutor(
      source: StaticToolSource(tools), events: EventBus(),
      remainingTime: { await budget.remaining() })
    let run = Task {
      try await executor.executeBatch(
        tools.enumerated().map { ToolCall(id: "\($0.offset)", name: $0.element.name) })
    }
    await hold.waitFor(4)
    await budget.expire()
    await hold.release(0)
    await #expect(throws: AgentError.executionTimeout(.run)) { try await run.value }
    #expect(await tools[4].executions.isEmpty)
    #expect(await hold.entered.count == 4)
  }
}
