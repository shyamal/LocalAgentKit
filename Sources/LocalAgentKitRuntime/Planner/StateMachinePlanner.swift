import Foundation
import LocalAgentKitCore

/// The v0.1 default planner (decision 0002): deterministic control flow that consults the model
/// only for narrow, validated decisions.
///
/// Given a goal it makes one closed choice, which of the declared ``Workflow``s fits, or none.
/// A workflow then runs in code: sequencing, conditional guards, values carried between steps,
/// bounded retries, a declared alternative when a step finds nothing, and completion. With no
/// matching workflow it runs **open**: for each step the model makes two narrow choices, which
/// tool, then that tool's arguments, instead of one free-form call.
///
/// Every model answer is validated against a schema before it is used, and a refusal ends the run
/// (never retried).
public struct StateMachinePlanner: AgentPlanner {
  public let workflows: [Workflow]
  private let repairer: ArgumentRepairer

  private static let choiceName = "choose_workflow"
  private static let actionName = "choose_next_action"
  private static let finish = "finish"
  private static let none = "none"

  /// - Parameter workflows: Declared deterministic workflows selectable by the planner.
  /// - Parameter maxRepairs: Re-asks, with the schema violation as feedback, when the model's
  ///   answer to a narrow question does not validate.
  public init(workflows: [Workflow] = [], maxRepairs: Int = 2) {
    self.workflows = workflows
    self.repairer = ArgumentRepairer(maxAttempts: maxRepairs)
  }

  // MARK: plan

  public func plan(
    context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider
  ) async throws -> AgentPlan {
    for workflow in workflows {
      let problems = workflow.problems(against: tools)
      if !problems.isEmpty {
        throw AgentError.invalidConfiguration(
          .invalidWorkflow("\(workflow.name): " + problems.joined(separator: "; ")))
      }
    }
    context.mode = .open
    context.cursor = 0
    context.pending = nil

    if !workflows.isEmpty {
      let names = workflows.map(\.name) + [Self.none]
      let descriptor = Self.closedChoice(
        Self.choiceName, parameter: "workflow", options: names,
        description: "Pick the workflow that fits the request, or none.")
      let listing = workflows.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
      let answer = try await ModelQuery(model: model, repairer: repairer).ask(
        descriptor,
        messages: [
          ModelMessage(role: .system, content: context.referenceLine),
          ModelMessage(
            role: .user,
            content: Self.lines([
              context.recentConversationText,
              "Request: \(context.goal)",
              "Workflows:\n" + listing + "\n- none: nothing above fits",
              "Which workflow fits the request?",
            ])),
        ])
      if let name = answer.string("workflow"),
        let chosen = workflows.first(where: { $0.name == name })
      {
        context.mode = .workflow(chosen)
        return AgentPlan(
          steps: chosen.steps.map { step in
            var toolName: String?
            if case .tool(let invocation) = step.action { toolName = invocation.tool }
            return PlanStep(id: step.id, summary: step.summary, toolName: toolName)
          })
      }
    }
    return AgentPlan(steps: [PlanStep(id: "open", summary: "Decide each step as the goal unfolds")])
  }

  // MARK: next

  public func next(
    context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider
  ) async throws -> PlannerDecision {
    switch context.mode {
    case .unplanned:
      throw AgentError.modelUnavailable(reason: "StateMachinePlanner: next() before plan()")
    case .open:
      return try await nextOpen(&context, tools: tools, model: model)
    case .workflow(let workflow):
      return try await nextInWorkflow(workflow, &context, tools: tools, model: model)
    }
  }

  private func nextInWorkflow(
    _ workflow: Workflow, _ context: inout AgentContext, tools: [ToolDescriptor],
    model: any LocalModelProvider
  ) async throws -> PlannerDecision {
    while context.cursor < workflow.steps.count {
      let step = workflow.steps[context.cursor]

      if context.pending == nil {
        guard step.condition.evaluate(context) else {
          context.skippedSteps.append(step.id)
          context.cursor += 1
          continue
        }
        switch step.action {
        case .respond(let instruction):
          context.cursor = workflow.steps.count
          return try await answer(instruction, context: context, model: model)
        case .tool(let invocation):
          context.pending = AgentContext.PendingStep(
            stepID: step.id, invocation: invocation, attempt: 0, isAlternative: false)
        }
      }

      guard let pending = context.pending else { continue }
      let call = try await buildCall(
        pending.invocation, stepID: pending.stepID, context: &context, tools: tools, model: model)
      return .callTool(call)
    }
    return .complete(Self.defaultAnswer(context))
  }

  /// Resolves each argument from its source; only what code cannot supply goes to the model.
  private func buildCall(
    _ invocation: ToolInvocation, stepID: String, context: inout AgentContext,
    tools: [ToolDescriptor], model: any LocalModelProvider
  ) async throws -> ToolCall {
    guard let descriptor = tools.first(where: { $0.name == invocation.tool }) else {
      throw AgentError.toolNotFound(name: invocation.tool)
    }
    var values: [String: JSONValue] = [:]
    var asked: [String: String] = [:]
    for (name, source) in invocation.arguments {
      switch source {
      case .literal(let value):
        values[name] = value
      case .binding(let reference):
        guard let value = context.value(for: reference) else {
          throw AgentError.invalidArguments(
            tool: invocation.tool, violations: [.missingRequired(path: name)])
        }
        values[name] = value
      case .model(let hint):
        asked[name] = hint
      }
    }
    if !asked.isEmpty {
      let answer = try await extract(
        asked, from: descriptor, context: context, model: model)
      for (name, value) in answer.values { values[name] = value }
    }
    return ToolCall(
      id: context.nextCallID(stepID), name: invocation.tool, arguments: ToolArguments(values))
  }

  /// One narrow question: just the arguments the model must supply, all required. The rest of
  /// the tool's schema is never shown to it.
  private func extract(
    _ asked: [String: String], from tool: ToolDescriptor, context: AgentContext,
    model: any LocalModelProvider
  ) async throws -> ToolArguments {
    var parameters: [String: ToolParameter] = [:]
    for (name, hint) in asked {
      guard var parameter = tool.schema.parameters[name] else { continue }
      parameter.description = hint
      parameters[name] = parameter
    }
    let descriptor = ToolDescriptor(
      name: "provide_\(tool.name)_arguments",
      description: "Provide the arguments for \(tool.name).",
      schema: ToolSchema(parameters: parameters, required: Set(parameters.keys)),
      permission: .none, isParallelSafe: true, isCancellable: true)
    return try await ModelQuery(model: model, repairer: repairer).ask(
      descriptor,
      messages: [
        ModelMessage(role: .system, content: context.referenceLine),
        ModelMessage(
          role: .user,
          content: Self.lines([
            context.recentConversationText,
            context.factsText(),
            "Request: \(context.goal)",
            "Provide the arguments for \(tool.name): \(tool.description)",
          ])),
      ])
  }

  // MARK: open mode

  private func nextOpen(
    _ context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider
  ) async throws -> PlannerDecision {
    let usable = tools.filter { (context.failures[$0.name] ?? 0) < 2 }
    let options = usable.map(\.name) + [Self.finish]
    let descriptor = Self.closedChoice(
      Self.actionName, parameter: "action", options: options,
      description: "Pick the next tool, or finish.")
    let listing = usable.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    let choice = try await ModelQuery(model: model, repairer: repairer).ask(
      descriptor,
      messages: [
        ModelMessage(role: .system, content: context.referenceLine),
        ModelMessage(
          role: .user,
          content: Self.lines([
            context.recentConversationText,
            context.factsText(),
            "Request: \(context.goal)",
            "Tools:\n" + listing,
            "Which tool is needed next? Answer \(Self.finish) if the request is already done or no "
              + "tool applies.",
          ])),
      ])
    guard let action = choice.string("action"), action != Self.finish,
      let tool = usable.first(where: { $0.name == action })
    else {
      return try await answer("", context: context, model: model)
    }

    let invocation = ToolInvocation(
      tool: tool.name,
      arguments: Dictionary(
        uniqueKeysWithValues: tool.schema.parameters.map { name, parameter in
          (name, ArgumentSource.model(hint: parameter.description))
        }))
    let call = try await buildCall(
      invocation, stepID: tool.name, context: &context, tools: tools, model: model)

    // Phase 0: the model created the same note twice in 22 of 50 iOS runs. An identical
    // side-effecting call is not made twice; the run wraps up instead.
    let signature = call.arguments.signature
    if tool.permission > .readOnly,
      context.executed.contains(where: { $0.tool == tool.name && $0.signature == signature })
    {
      context.notes.append("\(tool.name) was already done with these arguments.")
      return try await answer("", context: context, model: model)
    }
    context.pending = AgentContext.PendingStep(
      stepID: tool.name, invocation: invocation, attempt: 0, isAlternative: false)
    return .callTool(call)
  }

  // MARK: observe / failure

  public func observe(
    _ observation: ToolObservation, context: inout AgentContext
  ) throws -> PlanRevision {
    context.observations.append(observation)
    context.executed.append(
      AgentContext.ExecutedCall(
        tool: observation.call.name, signature: observation.call.arguments.signature))
    guard let pending = context.pending else { return .continue }
    context.pending = nil

    guard case .workflow(let workflow) = context.mode, context.cursor < workflow.steps.count
    else {
      // Open mode: the observation is recorded above and shows up in the next prompt's facts.
      return .continue
    }
    let step = workflow.steps[context.cursor]
    let result = observation.result
    let value = result.structured ?? .string(result.text)

    if result.isEmpty {
      if !pending.isAlternative, let alternative = step.alternative {
        context.pending = AgentContext.PendingStep(
          stepID: step.id, invocation: alternative, attempt: 0, isAlternative: true)
        return .continue
      }
      switch step.onEmpty {
      case .fail:
        throw AgentError.toolFailed(
          tool: observation.call.name,
          message: "returned nothing for step \(step.id) and no alternative was declared")
      case .skip:
        context.bind(step.binds, value, isEmpty: true)
        context.cursor += 1
        return .continue
      }
    }
    context.bind(step.binds, value, isEmpty: false)
    context.cursor += 1
    return .continue
  }

  public func handleFailure(
    _ error: AgentError, context: inout AgentContext
  ) throws -> PlanRevision {
    // Only a tool that ran and failed is recoverable. A denial, a cancellation, a limit, or a
    // refusal is final: recovery must never route around a human's "no".
    switch error {
    case .toolFailed, .invalidArguments:
      break
    default:
      throw error
    }
    guard let pending = context.pending else { throw error }
    context.failures[pending.invocation.tool, default: 0] += 1

    guard case .workflow(let workflow) = context.mode, context.cursor < workflow.steps.count
    else {
      // Open mode: tell the next choice what happened, and let it pick differently. Two failures
      // of one tool remove it from the choices; the runtime's limits bound the rest.
      context.notes.append("\(pending.invocation.tool) failed: \(Self.describe(error))")
      context.pending = nil
      return .continue
    }
    let step = workflow.steps[context.cursor]

    if pending.attempt < step.retries {
      context.pending?.attempt += 1
      return .continue
    }
    if !pending.isAlternative, let alternative = step.alternative {
      context.pending = AgentContext.PendingStep(
        stepID: step.id, invocation: alternative, attempt: 0, isAlternative: true)
      return .continue
    }
    switch step.onFailure {
    case .fail:
      throw error
    case .skip:
      context.pending = nil
      context.bind(step.binds, .null, isEmpty: true)
      context.cursor += 1
      return .continue
    }
  }

  // MARK: answers

  /// Writes the final answer, telling the model to use only the facts found.
  private func answer(
    _ instruction: String, context: AgentContext, model: any LocalModelProvider
  ) async throws -> PlannerDecision {
    let response = try await model.generate(
      request: ModelRequest(messages: [
        ModelMessage(
          role: .system,
          content: Self.lines([
            context.referenceLine,
            "Answer using only the facts provided. If they do not contain the answer, say so.",
          ])),
        ModelMessage(
          role: .user,
          content: Self.lines([
            context.recentConversationText,
            context.factsText(),
            "Request: \(context.goal)",
            instruction,
          ])),
      ]))
    switch response {
    case .text(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
      return .complete(text)
    case .clarification(let question):
      return .askUser(question)
    case .refused(let refusal):
      throw AgentError.guardrailRefusal(refusal)
    default:
      throw AgentError.modelUnavailable(reason: "the model gave no answer when asked for one")
    }
  }

  private static func defaultAnswer(_ context: AgentContext) -> String {
    if let last = context.observations.last(where: { !$0.result.isEmpty }) {
      return last.result.text
    }
    return "Done."
  }

  // MARK: helpers

  private static func closedChoice(
    _ name: String, parameter: String, options: [String], description: String
  ) -> ToolDescriptor {
    ToolDescriptor(
      name: name, description: description,
      schema: ToolSchema(
        parameters: [
          parameter: ToolParameter(.string, description: description, allowedValues: options)
        ], required: [parameter]),
      permission: .none, isParallelSafe: true, isCancellable: true)
  }

  private static func lines(_ parts: [String]) -> String {
    parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  private static func describe(_ error: AgentError) -> String {
    switch error {
    case .toolFailed(_, let message): message
    case .invalidArguments(_, let violations): violations.map(\.description).joined(separator: "; ")
    default: String(describing: error)
    }
  }
}
