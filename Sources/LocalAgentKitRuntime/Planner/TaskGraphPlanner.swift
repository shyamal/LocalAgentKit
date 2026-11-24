import LocalAgentKitCore

struct GraphProgress: Sendable {
  struct Pending: Sendable {
    let nodeID: String
    let step: AgentContext.PendingStep
  }
  let compiled: TaskGraph.Compiled
  var completed: Set<String> = []
  var pending: [String: Pending] = [:]
  var recovery: [String: AgentContext.PendingStep] = [:]
}

/// Schedules an application-declared DAG in stable topological order.
/// Parallel-safe terminal-failure nodes can form batches; recovery-bearing or unsafe nodes
/// execute singly so existing retry/alternative policies remain intact. Model argument
/// generation stays serial and budgeted. No default planner or model plan is changed.
public struct TaskGraphPlanner: AgentPlanner {
  /// Declared graph, validated once per run against the registered tools.
  public let graph: TaskGraph
  /// Maximum ready calls per decision, clamped from one through four.
  public let maxParallelism: Int
  private let resolver: StateMachinePlanner

  /// Creates an opt-in graph scheduler with bounded argument repair and ready-frontier width.
  /// Set tool-step retries to zero to permit parallel batching; recoverable steps remain serial.
  public init(graph: TaskGraph, maxRepairs: Int = 2, maxParallelism: Int = 4) {
    self.graph = graph
    self.maxParallelism = min(4, max(1, maxParallelism))
    resolver = StateMachinePlanner(maxRepairs: maxRepairs)
  }

  /// Rejects invalid references, cycles, duplicate identities and tool/schema errors before work.
  /// Publishes a topological presentation with explicit and inferred dependency IDs.
  public func plan(
    context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider
  ) throws -> AgentPlan {
    let compiled = try graph.compile(tools: tools)
    context.graphProgress = GraphProgress(compiled: compiled)
    context.mode = .workflow(compiled.workflow)
    context.cursor = 0
    context.pending = nil
    return AgentPlan(
      steps: compiled.nodes.map { node in
        let name: String?
        if case .tool(let invocation) = node.step.action {
          name = invocation.tool
        } else {
          name = nil
        }
        return PlanStep(
          id: node.step.id, summary: node.step.summary, toolName: name,
          dependsOn: compiled.dependencies[node.step.id, default: []])
      })
  }

  /// Resolves ready arguments serially, then emits one call or a bounded independent batch.
  public func next(
    context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider
  ) async throws -> PlannerDecision {
    guard var state = context.graphProgress else { throw Self.invalid("next before plan") }
    guard state.pending.isEmpty else { throw Self.invalid("unobserved graph calls remain") }
    while true {
      if Task.isCancelled { throw AgentError.cancelled }
      if state.completed.count == state.compiled.nodes.count {
        return .complete(StateMachinePlanner.defaultAnswer(context))
      }
      let ready = state.compiled.nodes.filter {
        !state.completed.contains($0.step.id)
          && state.compiled.dependencies[$0.step.id, default: []].isSubset(of: state.completed)
      }
      guard !ready.isEmpty else { throw Self.invalid("no ready node") }
      let skipped = ready.filter { !$0.step.condition.evaluate(context) }
      if !skipped.isEmpty {
        for node in skipped {
          state.completed.insert(node.step.id)
          context.skippedSteps.append(node.step.id)
        }
        context.graphProgress = state
        continue
      }
      let first = ready[0]
      if case .respond(let instruction) = first.step.action {
        let decision = try await resolver.answer(instruction, context: context, model: model)
        if case .complete = decision { state.completed.insert(first.step.id) }
        context.graphProgress = state
        return decision
      }
      var selected = [first]
      if parallel(first, state: state, tools: tools) {
        for node in ready.dropFirst().prefix(maxParallelism - 1) {
          guard parallel(node, state: state, tools: tools) else { break }
          selected.append(node)
        }
      }
      var calls: [ToolCall] = []
      for node in selected {
        guard case .tool(let invocation) = node.step.action else {
          throw Self.invalid("invalid ready action")
        }
        let pending =
          state.recovery[node.step.id]
          ?? AgentContext.PendingStep(
            stepID: node.step.id, invocation: invocation, attempt: 0, isAlternative: false)
        let call = try await resolver.buildCall(
          pending.invocation, stepID: node.step.id, context: &context, tools: tools, model: model,
          strictBindings: true)
        state.pending[call.id] = GraphProgress.Pending(nodeID: node.step.id, step: pending)
        calls.append(call)
      }
      context.graphProgress = state
      return calls.count == 1 ? .callTool(calls[0]) : .callTools(calls)
    }
  }

  /// Applies a completed node using existing workflow binding and empty-result recovery rules.
  public func observe(_ observation: ToolObservation, context: inout AgentContext) throws
    -> PlanRevision
  {
    guard let state = context.graphProgress,
      let id = observation.call.id.split(separator: ":").last.map(String.init),
      state.pending[id] != nil
    else { throw Self.invalid("unknown graph observation") }
    return try advance(id: id, context: &context) { value in
      try resolver.observe(observation, context: &value)
    }
  }

  /// Preserves existing serial retry/alternative/skip policies; batch failures remain terminal.
  public func handleFailure(_ error: AgentError, context: inout AgentContext) throws -> PlanRevision
  {
    guard let state = context.graphProgress, state.pending.count == 1,
      let id = state.pending.keys.first
    else { throw error }
    return try advance(id: id, context: &context) { value in
      try resolver.handleFailure(error, context: &value)
    }
  }

  private func parallel(_ node: TaskNode, state: GraphProgress, tools: [ToolDescriptor]) -> Bool {
    guard case .tool(let invocation) = node.step.action else { return false }
    return node.step.retries == 0 && node.step.alternative == nil && node.step.onFailure == .fail
      && state.recovery[node.step.id] == nil
      && tools.first(where: { $0.name == invocation.tool })?.isParallelSafe == true
  }

  private func advance(
    id: String, context: inout AgentContext, operation: (inout AgentContext) throws -> PlanRevision
  ) throws -> PlanRevision {
    guard var state = context.graphProgress, let pending = state.pending[id],
      let node = state.compiled.nodes.first(where: { $0.step.id == pending.nodeID })
    else { throw Self.invalid("unknown graph node") }
    let oldMode = context.mode
    let oldCursor = context.cursor
    let oldPending = context.pending
    defer {
      context.mode = oldMode
      context.cursor = oldCursor
      context.pending = oldPending
    }
    context.mode = .workflow(
      Workflow(name: graph.name, description: graph.description, steps: [node.step]))
    context.cursor = 0
    context.pending = pending.step
    let revision = try operation(&context)
    state.pending.removeValue(forKey: id)
    if context.cursor > 0 {
      state.completed.insert(node.step.id)
      state.recovery.removeValue(forKey: node.step.id)
    } else if let retry = context.pending {
      state.recovery[node.step.id] = retry
    }
    context.graphProgress = state
    return revision
  }

  private static func invalid(_ message: String) -> AgentError {
    .invalidConfiguration(.invalidWorkflow("TaskGraphPlanner: " + message))
  }
}
