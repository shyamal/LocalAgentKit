import Foundation
import LocalAgentKitCore

/// Runs an agent (FR-003): the actor that owns all execution state.
///
///     goal → plan → [ next → (tool | answer | ask the user) → observe ]* → completion
///
/// The runtime executes and enforces; the planner decides. Three things about it are deliberate:
///
/// - **The order inside a tool call is the security model.** `ToolExecutor` validates arguments,
///   then consults the permission gate, then executes. Nothing above `.readOnly` runs without a
///   human's yes, and no setting here changes that (PRD §19).
/// - **A guardrail refusal ends the run.** It is never retried: the on-device model refuses some
///   ordinary business tasks (R3), and a retry burns battery and context to fail identically. It
///   surfaces as `AgentError.guardrailRefusal` and a `.guardrailRefused` event, distinct from other
///   errors, so an app can fall back to a non-agentic path.
/// - **Waiting on a person holds no thread or lock**, and does not count against `maxDuration`.
///
/// One runtime runs one goal at a time; `run` while another is active throws `.runInProgress`.
public actor AgentRuntime {
  private let configuration: AgentConfiguration
  private let tools: any ToolSource
  private let planner: any AgentPlanner
  private let budgeter: ContextBudgeter
  private let repairer: ArgumentRepairer
  private let customGate: (any PermissionGate)?
  private let auditLogger: AuditLogger
  private let memory: ConversationMemory?
  private let broker = HumanInputBroker()
  private let bus = EventBus()
  private let now: @Sendable () -> Date
  private let timeZone: TimeZone
  private let instrumentation: any RuntimeInstrumentation
  private let thermalStateSource: (any ThermalStateSource)?
  private let thermalPolicy: ThermalPolicy
  private var taskMemory = WorkingMemory()
  private var activeRun: Task<AgentResponse, any Error>?

  /// - Parameters:
  ///   - configuration: Model, limits, security policy, and optional retrieval components.
  ///   - tools: The registry of tools available to this runtime.
  ///   - budgeter: Fits every model request to the configured context allowance.
  ///   - repairer: Repairs invalid tool arguments within its attempt limit.
  ///   - now: Supplies the run clock, allowing a fixed instant in tests.
  ///   - workflows: Declared for the built-in `StateMachinePlanner`; ignored by `.modelDriven`
  ///     or when an explicit `planner` is given.
  ///   - planner: Overrides the configured planner. Nil uses the selected built-in planner;
  ///     `.modelDriven` opts into experimental whole-sequence planning.
  ///   - gate: Decides permission prompts. With nil, a prompt suspends the run until the app calls
  ///     ``resolvePermission(callID:approved:)`` in response to `.permissionRequired`.
  ///   - auditLogger: Where confirmed executions are recorded when
  ///     `configuration.security.auditSensitiveExecutions` is true (M1-SE-02); read back with
  ///     ``auditEntries()``.
  ///   - memory: When given, a `run` whose `conversation` argument is nil reads history from
  ///     here instead of starting empty, and a successful run's goal and answer are appended back
  ///     (M1-ME-01/02). Passing an explicit `conversation` (including `[]`) always overrides it.
  /// - Throws: `.invalidConfiguration` for unusable limits, budget shares, an unsupported planner
  ///   choice, or `.never` network policy paired with a component that requires the network
  ///   (M1-SE-03).
  /// - Parameter timeZone: The planner clock zone; defaults to the host zone.
  /// - Parameter instrumentation: Optional content-free diagnostic intervals; defaults to no logging.
  /// - Parameter thermalStateSource: Opt-in thermal sampling; nil leaves execution unchanged.
  /// - Parameter thermalPolicy: Elevated-pressure caps and critical-pressure admission policy.
  public init(
    configuration: AgentConfiguration,
    tools: any ToolSource,
    workflows: [Workflow] = [],
    planner: (any AgentPlanner)? = nil,
    gate: (any PermissionGate)? = nil,
    budgeter: ContextBudgeter = ContextBudgeter(),
    repairer: ArgumentRepairer = ArgumentRepairer(),
    auditLogger: AuditLogger = AuditLogger(),
    memory: ConversationMemory? = nil,
    timeZone: TimeZone = .current,
    instrumentation: any RuntimeInstrumentation = NoOpRuntimeInstrumentation(),
    thermalStateSource: (any ThermalStateSource)? = nil,
    thermalPolicy: ThermalPolicy = .default,
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    if let issue = configuration.inputLimits.issue { throw AgentError.invalidConfiguration(issue) }
    if let issue = configuration.limits.issue { throw AgentError.invalidConfiguration(issue) }
    if let issue = configuration.memoryRetrieval.issue {
      throw AgentError.invalidConfiguration(issue)
    }
    if let issue = configuration.retrieval?.issue { throw AgentError.invalidConfiguration(issue) }
    if let issue = budgeter.configuration.issue { throw AgentError.invalidConfiguration(issue) }
    if let issue = thermalPolicy.issue { throw AgentError.invalidConfiguration(issue) }
    if let issue = NetworkPolicyGuard.validate(
      configuration, instrumentation: instrumentation, thermalStateSource: thermalStateSource)
    {
      throw AgentError.invalidConfiguration(issue)
    }
    switch (configuration.planner, planner) {
    case (_, let planner?):
      self.planner = planner
    case (.stateMachine, nil):
      self.planner = StateMachinePlanner(workflows: workflows)
    case (.modelDriven, nil):
      self.planner = ModelDrivenPlanner()
    }
    self.configuration = configuration
    self.tools = tools
    self.budgeter = budgeter
    self.repairer = repairer
    self.customGate = gate
    self.auditLogger = auditLogger
    self.memory = memory
    self.now = now
    self.timeZone = timeZone
    self.instrumentation = instrumentation
    self.thermalStateSource = thermalStateSource
    self.thermalPolicy = thermalPolicy
  }

  // MARK: Public surface

  /// A stream of everything the runtime does, across runs. A subscriber sees events from the
  /// moment it subscribes; subscribe before calling `run`.
  public func events() async -> AsyncStream<AgentEvent> {
    await bus.subscribe()
  }

  /// Ends every event stream. Call when the runtime is no longer needed.
  public func finishEvents() async {
    await bus.finish()
  }

  /// Runs one goal to completion.
  ///
  /// - Parameter goal: The task the agent should complete.
  /// - Parameter conversation: Earlier turns, so a follow-up such as "those meetings" resolves.
  ///   Nil reads from the configured `memory` instead (M1-ME-01); pass `[]` explicitly to start
  ///   fresh even with memory configured.
  /// - Throws: `LocalAgentKitCore.AgentError`. Cancelling the calling task cancels the run.
  public func run(_ goal: String, conversation: [ModelMessage]? = nil) async throws -> AgentResponse
  {
    try await run(AgentInput(text: goal), conversation: conversation)
  }

  /// Runs a goal with explicit host-authorized image, audio or extracted-document inputs.
  /// Attachments become ephemeral, budgeted source excerpts. Successful conversation memory
  /// records the goal and answer; quoted source text in an answer is retained too.
  /// Raw attachments and normalized excerpts are not recorded separately.
  public func run(
    _ input: AgentInput, conversation: [ModelMessage]? = nil
  ) async throws -> AgentResponse {
    guard activeRun == nil else { throw AgentError.runInProgress }
    let goal =
      input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !input.attachments.isEmpty ? "Respond using the supplied attachments." : input.text
    let task = Task {
      let effectiveConversation: [ModelMessage]
      if let conversation {
        effectiveConversation = conversation
      } else {
        effectiveConversation = await memory?.history() ?? []
      }
      let response = try await self.execute(
        goal: goal, attachments: input.attachments, conversation: effectiveConversation)
      await memory?.recordTurn(goal: goal, answer: response.text)
      return response
    }
    activeRun = task
    do {
      let response = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      activeRun = nil
      return response
    } catch {
      activeRun = nil
      throw Self.normalize(error)
    }
  }

  /// A copy of current task facts. Empty before the first run, reset on each new run,
  /// and retained after completion/failure until the next run. This is not persisted or
  /// automatically transferred to another run; conversation memory is a separate facility.
  public func workingMemory() -> WorkingMemory { taskMemory }

  private func publishWorkingMemory(_ value: WorkingMemory) async {
    guard taskMemory != value else { return }
    taskMemory = value
    await bus.publish(.workingMemoryUpdated(value))
  }

  /// Cancels the active run, if any. It ends with `.cancelled`.
  public func cancelCurrentRun() {
    activeRun?.cancel()
  }

  /// Answers a `.permissionRequired` event.
  /// - Returns: False if that request is not waiting.
  @discardableResult
  public func resolvePermission(callID: String, approved: Bool) async -> Bool {
    await broker.resolve(callID: callID, decision: approved ? .approved : .denied)
  }

  /// Answers a `.clarificationRequested` event.
  /// - Returns: False if no question is waiting.
  @discardableResult
  public func answerClarification(_ text: String) async -> Bool {
    await broker.answer(text)
  }

  /// Retained confirmed successful executions (M1-SE-02), bounded by the injected logger policy.
  /// Collection of new executor records follows configuration.security.auditSensitiveExecutions.
  /// A shared logger may also contain earlier records; disabling collection does not clear it.
  public func auditEntries() async -> [AuditEntry] {
    await auditLogger.allEntries()
  }

  /// Exports a version-one audit snapshot without writing or sending it. Argument signatures are
  /// omitted unless explicitly requested; the host owns destination, consent and durable retention.
  /// - Throws: memoryFailure for values that cannot be encoded as JSON.
  public func exportAuditJSON(includeArguments: Bool = false) async throws -> Data {
    try await auditLogger.exportJSON(includeArguments: includeArguments)
  }

  // MARK: The run

  private func execute(
    goal: String, attachments: [AgentInput.Attachment], conversation: [ModelMessage]
  ) async throws -> AgentResponse {
    let trace = RuntimeTrace(sink: instrumentation)
    let interval = trace.begin(.run)
    defer { interval.end() }
    let clock = RunClock(budget: configuration.limits.maxDuration)
    taskMemory = WorkingMemory()
    await bus.publish(.started)
    await bus.publish(.workingMemoryUpdated(taskMemory))
    do {
      let thermal = thermalStateSource.map {
        ThermalController(source: $0, policy: thermalPolicy, events: bus)
      }
      try Task.checkCancellationAsAgentError()
      _ = try await thermal?.checkpoint()
      let excerpts = try await InputPreprocessor(
        configuration: configuration, events: bus, clock: clock, thermal: thermal
      ).process(attachments)
      let response = try await drive(
        goal: goal, conversation: conversation, excerpts: excerpts,
        clock: clock, trace: trace, thermal: thermal)
      await broker.cancelAll()
      await bus.publish(.completed(response))
      return response
    } catch {
      let error = Self.normalize(error)
      await broker.cancelAll()
      if case .guardrailRefusal(let refusal) = error {
        await bus.publish(.guardrailRefused(refusal))
      } else {
        await bus.publish(.error(error))
      }
      throw error
    }
  }

  private func drive(
    goal: String, conversation: [ModelMessage], excerpts: [String],
    clock: RunClock, trace: RuntimeTrace,
    thermal: ThermalController?
  ) async throws -> AgentResponse {
    let limits = configuration.limits
    let passages = try await retrieveChunks(for: goal, trace: trace)
    let memories = try await retrieveMemories(for: goal, clock: clock, trace: trace)
    let model = BudgetedModel(
      base: configuration.model, budgeter: budgeter, limits: limits, clock: clock, events: bus,
      retrievedChunks: excerpts + passages + memories, trace: trace,
      thermal: thermal)
    var executor = ToolExecutor(
      source: tools, gate: TimedGate(inner: customGate ?? broker, clock: clock, trace: trace),
      events: bus,
      remainingTime: { await clock.remaining() },
      auditLogger: configuration.security.auditSensitiveExecutions ? auditLogger : nil)
    if let thermal {
      executor.executionCheck = { _ = try await thermal.checkpoint() }
    }
    let descriptors = await tools.descriptors()

    var context = AgentContext(
      goal: goal, now: now(), timeZone: timeZone, conversation: conversation)
    do {
      let plan: AgentPlan
      do {
        let interval = trace.begin(.planning)
        defer { interval.end() }
        plan = try await planner.plan(context: &context, tools: descriptors, model: model)
      }
      await publishWorkingMemory(context.workingMemory)
      await bus.publish(.planCreated(plan))

      var loopDetector = LoopDetector()
      var iterations = 0
      var toolCalls = 0

      while true {
        try Task.checkCancellationAsAgentError()
        _ = try await thermal?.checkpoint()
        guard iterations < limits.maxIterations else {
          throw AgentError.maximumIterationsReached(limit: limits.maxIterations)
        }
        guard await clock.remaining() > .zero else { throw AgentError.executionTimeout(.run) }
        iterations += 1

        let decision = try await planner.next(context: &context, tools: descriptors, model: model)
        await publishWorkingMemory(context.workingMemory)
        switch decision {
        case .complete(let text):
          return AgentResponse(text: text, iterations: iterations, toolCallCount: toolCalls)

        case .askUser(let question):
          await bus.publish(.clarificationRequested(question))
          let start = ContinuousClock.now
          let answer: String?
          do {
            let interval = trace.begin(.clarification)
            defer { interval.end() }
            answer = await broker.awaitClarification()
          }
          await clock.extend(by: ContinuousClock.now - start)
          guard let answer else { throw AgentError.cancelled }
          context.conversation += [
            ModelMessage(role: .assistant, content: question),
            ModelMessage(role: .user, content: answer),
          ]
          context.goal += "\n(Clarification: \(answer))"

        case .callTool(let call):
          if case .loop(_, let toolName) = loopDetector.record(call) {
            throw AgentError.loopDetected(tool: toolName)
          }
          let revision = try await perform(
            call, executor: executor, descriptors: descriptors, model: model,
            context: &context, toolCalls: &toolCalls, trace: trace)
          await publishWorkingMemory(context.workingMemory)
          if case .replanned(let revised) = revision { await bus.publish(.planCreated(revised)) }
        }
      }
    } catch {
      await publishWorkingMemory(context.workingMemory)
      throw error
    }
  }

  /// Persistent memory is best-effort, but cancellation and the run deadline remain terminal.
  private func retrieveMemories(for goal: String, clock: RunClock, trace: RuntimeTrace)
    async throws -> [String]
  {
    let policy = configuration.memoryRetrieval
    guard let store = configuration.memory, policy.limit > 0 else { return [] }
    let interval = trace.begin(.retrieval)
    defer { interval.end() }
    do {
      if Task.isCancelled { throw AgentError.cancelled }
      let remaining = await clock.remaining()
      guard remaining > .zero else { throw AgentError.executionTimeout(.run) }
      let query = MemoryQuery(
        text: policy.query == .goal ? goal : "", limit: policy.limit, metadata: policy.metadata)
      let records = try await withDeadline(remaining, scope: .run) { try await store.search(query) }
      if Task.isCancelled { throw AgentError.cancelled }
      // Defend against custom stores returning too many rows or ignoring metadata constraints.
      let selected = records.filter { record in
        policy.metadata.allSatisfy { record.metadata[$0.key] == $0.value }
      }.prefix(policy.limit)
      let passages = try selected.map { try Self.memoryPassage($0) }
      await bus.publish(.memoriesRetrieved(count: passages.count))
      return passages
    } catch {
      let failure: AgentError
      if error is CancellationError || Task.isCancelled { throw AgentError.cancelled }
      if let typed = error as? AgentError {
        if typed == .cancelled || typed == .executionTimeout(.run) { throw typed }
        failure = typed
      } else {
        failure = .memoryFailure(String(describing: error))
      }
      await bus.publish(.memoryRetrievalFailed(failure))
      return []
    }
  }

  /// Retrieves relevant chunks for `goal` once per run, before the loop starts (M1-RG-05).
  /// Best-effort: with no embedding provider and vector store both configured, or if retrieval
  /// itself fails, the run proceeds with none rather than treating document search as
  /// load-bearing. Genuine cancellation still propagates rather than being swallowed.
  private func retrieveChunks(for goal: String, trace: RuntimeTrace) async throws -> [String] {
    guard let embedding = configuration.embedding, let vectorStore = configuration.vectorStore
    else { return [] }
    let interval = trace.begin(.retrieval)
    defer { interval.end() }
    do {
      let pipeline = RetrievalPipeline(embeddingProvider: embedding, vectorStore: vectorStore)
      if let retrieval = configuration.retrieval {
        return try await pipeline.retrieve(for: goal, configuration: retrieval)
      }
      return try await pipeline.retrieve(for: goal)
    } catch AgentError.cancelled {
      throw AgentError.cancelled
    } catch is CancellationError {
      throw AgentError.cancelled
    } catch {
      return []
    }
  }

  /// One tool call, with the repair path for invalid arguments (M1-RT-08). Failures go to the
  /// planner, which recovers deterministically or rethrows.
  private func perform(
    _ call: ToolCall, executor: ToolExecutor, descriptors: [ToolDescriptor],
    model: BudgetedModel, context: inout AgentContext, toolCalls: inout Int, trace: RuntimeTrace
  ) async throws -> PlanRevision {
    let interval = trace.begin(.toolCall)
    defer { interval.end() }
    let limits = configuration.limits
    func count() throws {
      guard toolCalls < limits.maxToolCalls else {
        throw AgentError.maximumToolCallsReached(limit: limits.maxToolCalls)
      }
      toolCalls += 1
    }

    try count()
    var result = await attempt(call, with: executor)

    if case .failure(.invalidArguments(let toolName, let violations)) = result,
      let descriptor = descriptors.first(where: { $0.name == toolName })
    {
      do {
        let repaired = try await repairer.repair(
          call, violations: violations, descriptor: descriptor,
          history: context.conversation + [ModelMessage(role: .user, content: context.goal)],
          model: model)
        try count()
        // The repaired call keeps the original id, so the transcript stays linked (findings §10a).
        result = await attempt(
          ToolCall(id: call.id, name: repaired.name, arguments: repaired.arguments),
          with: executor)
      } catch let error as AgentError {
        // A refusal or a limit is final; exhausted repairs are a failure the planner may handle.
        guard case .invalidArguments = error else { throw error }
        result = .failure(error)
      }
    }

    switch result {
    case .success(let observation):
      return try planner.observe(observation, context: &context)
    case .failure(let error):
      return try planner.handleFailure(error, context: &context)
    }
  }

  private func attempt(
    _ call: ToolCall, with executor: ToolExecutor
  ) async -> Result<ToolObservation, AgentError> {
    do {
      return .success(try await executor.execute(call))
    } catch {
      return .failure(Self.normalize(error))
    }
  }

  private static func normalize(_ error: any Error) -> AgentError {
    if let error = error as? AgentError { return error }
    if error is CancellationError { return .cancelled }
    return .modelUnavailable(reason: String(describing: error))
  }
}

extension Task where Success == Never, Failure == Never {
  fileprivate static func checkCancellationAsAgentError() throws {
    if Task.isCancelled { throw AgentError.cancelled }
  }
}
