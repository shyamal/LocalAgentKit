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
  private let broker = HumanInputBroker()
  private let bus = EventBus()
  private let now: @Sendable () -> Date
  private var activeRun: Task<AgentResponse, any Error>?

  /// - Parameters:
  ///   - workflows: Declared for the default `StateMachinePlanner`; ignored if `planner` is given.
  ///   - planner: Overrides the configured planner. Required for `.modelDriven`, which has not
  ///     shipped (M1-RT-12).
  ///   - gate: Decides permission prompts. With nil, a prompt suspends the run until the app calls
  ///     ``resolvePermission(callID:approved:)`` in response to `.permissionRequired`.
  ///   - auditLogger: Where confirmed executions are recorded when
  ///     `configuration.security.auditSensitiveExecutions` is true (M1-SE-02); read back with
  ///     ``auditEntries()``.
  /// - Throws: `.invalidConfiguration` for unusable limits, budget shares, an unsupported planner
  ///   choice, or `.never` network policy paired with a component that requires the network
  ///   (M1-SE-03).
  public init(
    configuration: AgentConfiguration,
    tools: any ToolSource,
    workflows: [Workflow] = [],
    planner: (any AgentPlanner)? = nil,
    gate: (any PermissionGate)? = nil,
    budgeter: ContextBudgeter = ContextBudgeter(),
    repairer: ArgumentRepairer = ArgumentRepairer(),
    auditLogger: AuditLogger = AuditLogger(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    if let issue = configuration.limits.issue { throw AgentError.invalidConfiguration(issue) }
    if let issue = budgeter.configuration.issue { throw AgentError.invalidConfiguration(issue) }
    if let issue = NetworkPolicyGuard.validate(configuration) {
      throw AgentError.invalidConfiguration(issue)
    }
    switch (configuration.planner, planner) {
    case (_, let planner?):
      self.planner = planner
    case (.stateMachine, nil):
      self.planner = StateMachinePlanner(workflows: workflows)
    case (.modelDriven, nil):
      throw AgentError.invalidConfiguration(
        .unsupported("ModelDrivenPlanner has not shipped; pass a planner or use .stateMachine"))
    }
    self.configuration = configuration
    self.tools = tools
    self.budgeter = budgeter
    self.repairer = repairer
    self.customGate = gate
    self.auditLogger = auditLogger
    self.now = now
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
  /// - Parameter conversation: Earlier turns, so a follow-up such as "those meetings" resolves.
  /// - Throws: ``AgentError``. Cancelling the calling task cancels the run.
  public func run(_ goal: String, conversation: [ModelMessage] = []) async throws -> AgentResponse {
    guard activeRun == nil else { throw AgentError.runInProgress }
    let task = Task { try await self.execute(goal: goal, conversation: conversation) }
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

  /// Every confirmed execution recorded so far (M1-SE-02). Empty unless
  /// `configuration.security.auditSensitiveExecutions` is true.
  public func auditEntries() async -> [AuditEntry] {
    await auditLogger.allEntries()
  }

  // MARK: The run

  private func execute(goal: String, conversation: [ModelMessage]) async throws -> AgentResponse {
    let clock = RunClock(budget: configuration.limits.maxDuration)
    await bus.publish(.started)
    do {
      let response = try await drive(goal: goal, conversation: conversation, clock: clock)
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
    goal: String, conversation: [ModelMessage], clock: RunClock
  ) async throws -> AgentResponse {
    let limits = configuration.limits
    let model = BudgetedModel(
      base: configuration.model, budgeter: budgeter, limits: limits, clock: clock, events: bus,
      retrievedChunks: try await retrieveChunks(for: goal))
    let executor = ToolExecutor(
      source: tools, gate: TimedGate(inner: customGate ?? broker, clock: clock), events: bus,
      remainingTime: { await clock.remaining() },
      auditLogger: configuration.security.auditSensitiveExecutions ? auditLogger : nil)
    let descriptors = await tools.descriptors()

    var context = AgentContext(goal: goal, now: now(), conversation: conversation)
    let plan = try await planner.plan(context: &context, tools: descriptors, model: model)
    await bus.publish(.planCreated(plan))

    var loopDetector = LoopDetector()
    var iterations = 0
    var toolCalls = 0

    while true {
      try Task.checkCancellationAsAgentError()
      guard iterations < limits.maxIterations else {
        throw AgentError.maximumIterationsReached(limit: limits.maxIterations)
      }
      guard await clock.remaining() > .zero else { throw AgentError.executionTimeout(.run) }
      iterations += 1

      switch try await planner.next(context: &context, tools: descriptors, model: model) {
      case .complete(let text):
        return AgentResponse(text: text, iterations: iterations, toolCallCount: toolCalls)

      case .askUser(let question):
        await bus.publish(.clarificationRequested(question))
        let start = ContinuousClock.now
        let answer = await broker.awaitClarification()
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
          context: &context, toolCalls: &toolCalls)
        if case .replanned(let revised) = revision { await bus.publish(.planCreated(revised)) }
      }
    }
  }

  /// Retrieves relevant chunks for `goal` once per run, before the loop starts (M1-RG-05).
  /// Best-effort: with no embedding provider and vector store both configured, or if retrieval
  /// itself fails, the run proceeds with none rather than treating document search as
  /// load-bearing. Genuine cancellation still propagates rather than being swallowed.
  private func retrieveChunks(for goal: String) async throws -> [String] {
    guard let embedding = configuration.embedding, let vectorStore = configuration.vectorStore
    else { return [] }
    do {
      return try await RetrievalPipeline(embeddingProvider: embedding, vectorStore: vectorStore)
        .retrieve(for: goal)
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
    model: BudgetedModel, context: inout AgentContext, toolCalls: inout Int
  ) async throws -> PlanRevision {
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
