import Foundation
import LocalAgentKitCore

/// Closed, nonrecursive proposal language compiled to the existing workflow interpreter.
/// References may only name earlier generated step bindings, never memory or arbitrary inputs.
enum ModelPlanCompiler {
  static func schema(names: [String]) -> ToolSchema {
    let argument = ToolSchema(
      parameters: [
        "name": ToolParameter(.string, description: "Declared tool parameter name."),
        "source": ToolParameter(
          .string, description: "How to resolve the parameter.",
          allowedValues: ["model", "binding", "literal"]),
        "value": ToolParameter(
          .string,
          description:
            "Model hint, earlier step binding path (step_1.0.title), or JSON literal text."),
      ], required: ["name", "source", "value"])
    let condition = ToolSchema(
      parameters: [
        "reference": ToolParameter(.string, description: "Earlier step binding path, e.g. step_1."),
        "operator": ToolParameter(
          .string, description: "Evaluated in code, not by a model.",
          allowedValues: [
            "exists", "is_empty", "not_empty", "equals", "less_than", "at_most", "at_least",
            "greater_than",
          ]),
        "value_json": ToolParameter(
          .string, description: "JSON literal for equals/numeric comparisons; omit otherwise."),
      ], required: ["reference", "operator"])
    return ToolSchema(
      parameters: [
        "tool": ToolParameter(
          .string, description: "Registered tool name.", allowedValues: names.isEmpty ? nil : names),
        "summary": ToolParameter(.string, description: "Brief description of this step."),
        "instruction": ToolParameter(.string, description: "What this tool should do."),
        "arguments": ToolParameter(
          .array(of: .object(argument)),
          description: "Optional argument overrides. Unspecified parameters use model generation."),
        "conditions": ToolParameter(
          .array(of: .object(condition)), description: "Up to eight guards on earlier step results."
        ),
        "condition_mode": ToolParameter(
          .string, description: "Combine guards; defaults to all.", allowedValues: ["all", "any"]),
        "retries": ToolParameter(
          .integer,
          description: "Extra attempts for recoverable failures; never permission denial.",
          minimum: 0, maximum: 2),
        "on_empty": ToolParameter(
          .string, description: "Empty-result policy; defaults to fail.",
          allowedValues: ["fail", "skip"]),
      ], required: ["tool", "summary", "instruction"])
  }

  static func step(
    fields: [String: JSONValue], index: Int, tool: ToolDescriptor, summary: String,
    instruction: String
  ) throws -> WorkflowStep {
    var arguments = Dictionary(
      uniqueKeysWithValues: tool.schema.parameters.map { name, parameter in
        (name, ArgumentSource.model(hint: parameter.description + "\n" + instruction))
      })
    if case .array(let overrides) = fields["arguments"] {
      guard overrides.count <= tool.schema.parameters.count else { throw invalid("arguments") }
      var seen: Set<String> = []
      for value in overrides {
        guard case .object(let values) = value,
          case .string(let name) = values["name"], let parameter = tool.schema.parameters[name],
          seen.insert(name).inserted, case .string(let source) = values["source"],
          case .string(let text) = values["value"]
        else { throw invalid("arguments") }
        switch source {
        case "binding":
          try reference(text, before: index)
          arguments[name] = .binding(text)
        case "literal":
          let literal = try json(text)
          let required: Set<String> = tool.schema.required.contains(name) ? [name] : []
          guard
            ToolSchema(parameters: [name: parameter], required: required)
              .validate(ToolArguments([name: literal])).isEmpty
          else { throw invalid("arguments.\(name)") }
          arguments[name] = .literal(literal)
        case "model":
          guard text.contains(where: { !$0.isWhitespace }) else {
            throw invalid("arguments.\(name)")
          }
          arguments[name] = .model(hint: parameter.description + "\n" + text)
        default: throw invalid("arguments.source")
        }
      }
    }
    var guards: [Guard] = []
    if case .array(let conditions) = fields["conditions"] {
      guard conditions.count <= 8 else { throw invalid("conditions") }
      for value in conditions {
        guard case .object(let values) = value,
          case .string(let path) = values["reference"],
          case .string(let operation) = values["operator"]
        else { throw invalid("conditions") }
        try reference(path, before: index)
        if ["exists", "is_empty", "not_empty"].contains(operation) {
          guard values["value_json"] == nil else { throw invalid("conditions.value_json") }
          switch operation {
          case "exists": guards.append(.exists(path))
          case "is_empty": guards.append(.isEmpty(path))
          default: guards.append(.not(.isEmpty(path)))
          }
        } else {
          guard case .string(let text) = values["value_json"] else {
            throw invalid("conditions.value_json")
          }
          let literal = try json(text)
          if operation == "equals" {
            guards.append(.equals(path, literal))
          } else {
            guard let number = literal.numericValue, number.isFinite else {
              throw invalid("conditions.value_json")
            }
            let comparison: Comparison
            switch operation {
            case "less_than": comparison = .lessThan
            case "at_most": comparison = .atMost
            case "at_least": comparison = .atLeast
            case "greater_than": comparison = .greaterThan
            default: throw invalid("conditions.operator")
            }
            guards.append(.number(path, comparison, number))
          }
        }
      }
    }
    let mode = ToolArguments(fields).string("condition_mode") ?? "all"
    // No guards means unconditional, including when condition_mode is any.
    let condition: Guard = guards.isEmpty ? .always : (mode == "any" ? .any(guards) : .all(guards))
    return .tool(
      "step_\(index + 1)", summary, tool.name, arguments, condition: condition,
      onEmpty: ToolArguments(fields).string("on_empty") == "skip" ? .skip : .fail,
      retries: ToolArguments(fields).int("retries") ?? 0)
  }

  /// Only the generated-plan path pins deterministic facts before executor repair.
  /// Declared workflow repair behavior remains unchanged for existing consumers.
  static func validateBindings(context: AgentContext, tools: [ToolDescriptor]) throws {
    guard case .workflow(let workflow) = context.mode else { return }
    for step in workflow.steps.dropFirst(context.cursor) {
      guard step.condition.evaluate(context) else { continue }
      guard case .tool(let invocation) = step.action,
        let descriptor = tools.first(where: { $0.name == invocation.tool })
      else { return }
      for (name, source) in invocation.arguments {
        guard case .binding(let path) = source else { continue }
        guard let value = context.value(for: path),
          let parameter = descriptor.schema.parameters[name]
        else { throw invalid("arguments.\(name)") }
        let violations = ToolSchema(parameters: [name: parameter], required: [name])
          .validate(ToolArguments([name: value]))
        guard violations.isEmpty else {
          throw AgentError.invalidArguments(tool: descriptor.name, violations: violations)
        }
      }
      return
    }
  }

  private static func reference(_ text: String, before index: Int) throws {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.contains(""), let root = parts.first,
      (0..<index).contains(where: { root == "step_\($0 + 1)" })
    else { throw invalid("reference") }
  }

  private static func json(_ text: String) throws -> JSONValue {
    guard text.utf8.count <= 16_384,
      let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    else { throw invalid("value_json") }
    return value
  }

  private static func invalid(_ path: String) -> AgentError {
    .invalidArguments(
      tool: "propose_tool_plan",
      violations: [.typeMismatch(path: path, expected: "a valid bounded plan expression")])
  }
}
