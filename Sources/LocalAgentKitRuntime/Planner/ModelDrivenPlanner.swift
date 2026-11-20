import LocalAgentKitCore

/// Experimental whole-sequence planning, explicitly selected with `PlannerChoice.modelDriven`.
///
/// The model proposes an ordered tool sequence and a final-answer instruction. The sequence
/// is validated and compiled into a workflow; existing argument resolution, tool execution,
/// permissions, budgets and limits still apply. All per-run state lives in `AgentContext`.
///
/// This is not the default and has no measured reliability claim. It supports ordered conditional
/// steps and exact earlier-result bindings, but not open-ended replanning (M5-02).
/// Use declared workflows for deterministic conditions and dependencies.
public struct ModelDrivenPlanner: AgentPlanner {
  /// Maximum number of proposed tool steps, excluding the final answer; clamped to at least one.
  public let maxSteps: Int
  private let repairer: ArgumentRepairer
  private let workflowPlanner: StateMachinePlanner
  private static let planName = "propose_tool_plan"

  /// Creates an experimental planner with bounded plan length and schema-repair attempts.
  /// Seven tool steps plus the final answer fit the default eight-iteration limit.
  /// Runtime execution limits still apply independently, including to argument repair.
  public init(maxSteps: Int = 7, maxRepairs: Int = 2) {
    self.maxSteps = max(1, maxSteps)
    self.repairer = ArgumentRepairer(maxAttempts: maxRepairs)
    self.workflowPlanner = StateMachinePlanner(maxRepairs: maxRepairs)
  }

  /// Requests and validates an ordered conditional workflow before any proposed tool executes.
  /// Invalid plans throw invalidArguments; policy refusals are terminal and never repaired.
  public func plan(
    context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider
  ) async throws -> AgentPlan {
    let names = tools.map(\.name).sorted()
    let stepSchema = ModelPlanCompiler.schema(names: names)
    let descriptor = ToolDescriptor(
      name: Self.planName,
      description: "Propose the complete ordered tool sequence, followed by a final answer.",
      schema: ToolSchema(
        parameters: [
          "steps": ToolParameter(
            .array(of: .object(stepSchema)),
            description: "Zero to \(maxSteps) tool steps; empty if no tools are needed."),
          "answer_instruction": ToolParameter(
            .string, description: "How to answer the request using the resulting observations."),
        ], required: ["steps", "answer_instruction"]),
      permission: .none, isParallelSafe: true, isCancellable: true)
    let catalog = tools.sorted { $0.name < $1.name }
      .map { tool in
        let parameters = tool.schema.parameters.sorted { $0.key < $1.key }.map { name, value in
          "  \(name) (\(tool.schema.required.contains(name) ? "required" : "optional"), \(value.type)): \(value.description)"
        }.joined(separator: "\n")
        return "- \(tool.name): \(tool.description)\n\(parameters)"
      }.joined(separator: "\n")
    let proposal = try await ModelQuery(model: model, repairer: repairer).ask(
      descriptor,
      messages: [
        ModelMessage(role: .system, content: context.referenceLine),
        ModelMessage(
          role: .user,
          content: """
            \(context.recentConversationText)
            Request: \(context.goal)
            Available tools (no others may be used):
            \(catalog)
            Propose the entire linear sequence, at most \(maxSteps) tool steps.
            Use no tool steps if none are needed or none are available.
            Do not claim a tool succeeded before it executes. Human confirmation is still required
            for protected tools. Results bind to step_1, step_2, and so on. Binding paths and conditions may only refer
            to earlier steps. Use argument bindings to carry exact observed values; literals are
            JSON text. Conditions run in code. Use complementary guards for conditional paths.
            Retries are at most two extra attempts; on_empty skip permits later guarded steps.
            Open-ended replanning is not supported here.
            """),
      ])
    guard case .array(let proposedSteps) = proposal["steps"] else {
      throw Self.invalid("steps", expected: "an array of tool steps")
    }
    guard proposedSteps.count <= maxSteps else {
      throw AgentError.invalidArguments(
        tool: Self.planName,
        violations: [.aboveMaximum(path: "steps.count", maximum: Double(maxSteps))])
    }
    guard let answer = proposal.string("answer_instruction"), Self.hasText(answer) else {
      throw Self.invalid("answer_instruction", expected: "nonempty answer instructions")
    }
    var steps: [WorkflowStep] = []
    for (index, value) in proposedSteps.enumerated() {
      guard case .object(let fields) = value,
        case .string(let name) = fields["tool"],
        let tool = tools.first(where: { $0.name == name }),
        case .string(let summary) = fields["summary"], Self.hasText(summary),
        case .string(let instruction) = fields["instruction"], Self.hasText(instruction)
      else {
        throw Self.invalid(
          "steps[\(index)]", expected: "a registered tool and nonempty instructions")
      }
      steps.append(
        try ModelPlanCompiler.step(
          fields: fields, index: index, tool: tool, summary: summary, instruction: instruction))
    }
    steps.append(.respond("answer", "Write the answer", instruction: answer))
    let workflow = Workflow(
      name: "model_generated", description: "Experimental model plan", steps: steps)
    let problems = workflow.problems(against: tools)
    guard problems.isEmpty else {
      throw Self.invalid("steps", expected: problems.joined(separator: "; "))
    }
    context.mode = .workflow(workflow)
    context.cursor = 0
    context.pending = nil
    return AgentPlan(
      steps: steps.map { step in
        let toolName: String?
        if case .tool(let call) = step.action { toolName = call.tool } else { toolName = nil }
        return PlanStep(id: step.id, summary: step.summary, toolName: toolName)
      })
  }

  /// Resolves the next proposed step using the existing workflow argument and answer path.
  public func next(
    context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider
  ) async throws -> PlannerDecision {
    try ModelPlanCompiler.validateBindings(context: context, tools: tools)
    return try await workflowPlanner.next(context: &context, tools: tools, model: model)
  }

  /// Records tool observations and advances the proposed workflow; does not ask the model to replan.
  public func observe(
    _ observation: ToolObservation, context: inout AgentContext
  ) throws -> PlanRevision {
    try workflowPlanner.observe(observation, context: &context)
  }

  /// Fails a proposed step without inventing an alternative; never routes around permission denial.
  public func handleFailure(_ error: AgentError, context: inout AgentContext) throws -> PlanRevision
  {
    try workflowPlanner.handleFailure(error, context: &context)
  }

  private static func hasText(_ text: String) -> Bool {
    text.contains { !$0.isWhitespace }
  }

  private static func invalid(_ path: String, expected: String) -> AgentError {
    .invalidArguments(tool: planName, violations: [.typeMismatch(path: path, expected: expected)])
  }
}
