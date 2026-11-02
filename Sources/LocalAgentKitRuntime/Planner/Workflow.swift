import LocalAgentKitCore

/// Where one tool argument comes from. Deterministic sources are preferred: the model is asked
/// only for what code cannot supply, because a single on-device call is right roughly half the
/// time (findings §11).
public enum ArgumentSource: Sendable, Hashable {
  /// Use the supplied value directly, without model generation or a binding lookup.
  case literal(JSONValue)
  /// A value an earlier step produced: `"notes"`, or a path into it, `"notes.0.title"`. Carrying
  /// values in code instead of through the model removes the grounding failure, the largest
  /// model-side failure in Phase 0 (findings §12).
  case binding(String)
  /// Asked of the model as one narrow, validated question. `hint` says what is wanted.
  case model(hint: String)
}

/// A comparison for numeric guards.
public enum Comparison: Sendable, Hashable {
  /// The value is strictly less than the threshold.
  case lessThan
  /// The value is less than or equal to the threshold.
  case atMost
  /// The value exactly equals the threshold.
  case equalTo
  /// The value is greater than or equal to the threshold.
  case atLeast
  /// The value is strictly greater than the threshold.
  case greaterThan
}

/// A condition evaluated **in code** against the run's bindings. The model ignored a goal's "only
/// if" condition in 4 of 5 runs (findings §12), so conditions are never left to the prompt.
/// A missing or unusable value makes a comparison false, never a crash.
public indirect enum Guard: Sendable, Hashable {
  /// Unconditionally include the step.
  case always
  /// The reference resolves to a value.
  case exists(String)
  /// Missing, null, blank, an empty collection, or the result of a tool that found nothing.
  case isEmpty(String)
  /// Compare a resolved binding or path with an expected JSON value.
  case equals(String, JSONValue)
  /// Apply a numeric comparison to a resolved binding or path.
  case number(String, Comparison, Double)
  /// Invert another guard's result.
  case not(Guard)
  /// Require every nested guard to hold; an empty list succeeds.
  case all([Guard])
  /// Require at least one nested guard to hold; an empty list fails.
  case any([Guard])

  func evaluate(_ context: AgentContext) -> Bool {
    switch self {
    case .always:
      return true
    case .exists(let reference):
      return context.value(for: reference) != nil
    case .isEmpty(let reference):
      return context.isEmpty(reference)
    case .equals(let reference, let expected):
      return context.value(for: reference) == expected
    case .number(let reference, let comparison, let threshold):
      guard let value = context.value(for: reference)?.numericValue else { return false }
      switch comparison {
      case .lessThan: return value < threshold
      case .atMost: return value <= threshold
      case .equalTo: return value == threshold
      case .atLeast: return value >= threshold
      case .greaterThan: return value > threshold
      }
    case .not(let inner):
      return !inner.evaluate(context)
    case .all(let guards):
      return guards.allSatisfy { $0.evaluate(context) }
    case .any(let guards):
      return guards.contains { $0.evaluate(context) }
    }
  }
}

/// One call to a tool.
public struct ToolInvocation: Sendable, Hashable {
  /// Registered name of the tool to invoke.
  public var tool: String
  /// Argument names mapped to literal values, bindings or model-supplied values.
  public var arguments: [String: ArgumentSource]

  /// Creates a planned invocation with named argument sources.
  public init(tool: String, arguments: [String: ArgumentSource] = [:]) {
    self.tool = tool
    self.arguments = arguments
  }
}

/// What to do when a step returns nothing, or fails after its retries.
public enum Recovery: Sendable, Hashable {
  /// End the run with a typed error. The default: silently carrying on would hide the problem.
  case fail
  /// Bind what there is (nothing) and move to the next step.
  case skip
}

/// One guarded workflow action with binding, retry and recovery policies.
public struct WorkflowStep: Sendable, Hashable, Identifiable {
  /// The executable operation represented by a workflow step.
  public enum Action: Sendable, Hashable {
    /// Invoke a registered tool with resolved arguments.
    case tool(ToolInvocation)
    /// Write the final answer from the run's bindings, with the model told to use only those
    /// facts. Must be the last step.
    case respond(instruction: String)
  }

  /// Unique step identifier within its workflow.
  public var id: String
  /// Shown in the plan the UI renders.
  public var summary: String
  /// The tool invocation or final-answer operation to perform.
  public var action: Action
  /// The step is skipped when this is false.
  public var condition: Guard
  /// The name the result is bound under. Defaults to `id`.
  public var binds: String
  /// A declared alternative path, taken once if the step returns nothing or fails (FR-027).
  public var alternative: ToolInvocation?
  /// Policy after an empty result and any declared alternative also returns empty.
  public var onEmpty: Recovery
  /// Policy after a recoverable error exhausts retry and alternative handling.
  public var onFailure: Recovery
  /// Extra attempts after a tool failure. A permission denial is never retried or routed around.
  public var retries: Int

  /// Creates a guarded action; the result binding defaults to the step ID.
  /// Retries are bounded by the supplied count; alternatives run before final recovery.
  public init(
    id: String, summary: String, action: Action, condition: Guard = .always, binds: String? = nil,
    alternative: ToolInvocation? = nil, onEmpty: Recovery = .fail, onFailure: Recovery = .fail,
    retries: Int = 1
  ) {
    self.id = id
    self.summary = summary
    self.action = action
    self.condition = condition
    self.binds = binds ?? id
    self.alternative = alternative
    self.onEmpty = onEmpty
    self.onFailure = onFailure
    self.retries = max(0, retries)
  }

  /// Convenience for the common case, a tool step.
  public static func tool(
    _ id: String, _ summary: String, _ tool: String, _ arguments: [String: ArgumentSource] = [:],
    condition: Guard = .always, binds: String? = nil, alternative: ToolInvocation? = nil,
    onEmpty: Recovery = .fail, onFailure: Recovery = .fail, retries: Int = 1
  ) -> WorkflowStep {
    WorkflowStep(
      id: id, summary: summary, action: .tool(ToolInvocation(tool: tool, arguments: arguments)),
      condition: condition, binds: binds, alternative: alternative, onEmpty: onEmpty,
      onFailure: onFailure, retries: retries)
  }

  /// Creates a final model-answer step, optionally guarded, with instructions for using the bindings.
  public static func respond(
    _ id: String = "respond", _ summary: String = "Write the answer", instruction: String,
    condition: Guard = .always
  ) -> WorkflowStep {
    WorkflowStep(
      id: id, summary: summary, action: .respond(instruction: instruction), condition: condition)
  }
}

/// A named, ordered procedure for a kind of goal. The planner picks one by a closed choice among
/// the `name`s, using `description`; everything after that is deterministic.
public struct Workflow: Sendable, Hashable {
  /// Unique workflow choice exposed to the model.
  public var name: String
  /// Prompt-facing guidance for selecting this procedure.
  public var description: String
  /// Ordered procedure ending with a response step when an answer is required.
  public var steps: [WorkflowStep]

  /// Creates a named procedure; planning validates it against the registered tools.
  public init(name: String, description: String, steps: [WorkflowStep]) {
    self.name = name
    self.description = description
    self.steps = steps
  }

  /// Problems that would make this workflow fail mid-run, found before it starts.
  func problems(against tools: [ToolDescriptor]) -> [String] {
    var problems: [String] = []
    var seenIDs: Set<String> = []
    var seenBindings: Set<String> = []
    let descriptors = Dictionary(
      tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    func check(_ invocation: ToolInvocation, in step: WorkflowStep) {
      guard let descriptor = descriptors[invocation.tool] else {
        problems.append("step \(step.id): unknown tool \(invocation.tool)")
        return
      }
      for name in invocation.arguments.keys where descriptor.schema.parameters[name] == nil {
        problems.append("step \(step.id): \(invocation.tool) has no parameter \(name)")
      }
      for name in descriptor.schema.required where invocation.arguments[name] == nil {
        problems.append(
          "step \(step.id): required parameter \(name) of \(invocation.tool) has no source")
      }
      for source in invocation.arguments.values {
        if case .binding(let reference) = source {
          let root = String(reference.split(separator: ".").first ?? "")
          if !seenBindings.contains(root) {
            problems.append("step \(step.id): \(reference) refers to a value no earlier step binds")
          }
        }
      }
    }

    for (index, step) in steps.enumerated() {
      if !seenIDs.insert(step.id).inserted { problems.append("duplicate step id \(step.id)") }
      switch step.action {
      case .tool(let invocation):
        check(invocation, in: step)
        if let alternative = step.alternative { check(alternative, in: step) }
      case .respond:
        if index != steps.count - 1 { problems.append("step \(step.id): respond must be last") }
      }
      seenBindings.insert(step.binds)
    }
    if steps.isEmpty { problems.append("no steps") }
    return problems
  }
}
