import LocalAgentKitCore

/// Mathematical operations (FR-008). `.none`: pure computation, no side effects, no personal data.
public struct CalculatorTool: AgentTool {
  /// Registered action name `calculate`.
  public let name = "calculate"
  /// Prompt-facing guidance for arithmetic expressions.
  public let description =
    "Evaluate an arithmetic expression and return the numeric result. Use for any math: "
    + "percentages, splitting amounts, unit rates."
  /// Requires a string arithmetic expression.
  public let schema = ToolSchema(
    parameters: [
      "expression": ToolParameter(
        .string, description: "An arithmetic expression using numbers, + - * / and parentheses.")
    ], required: ["expression"])
  /// Pure computation with no user data or side effects, so no confirmation is needed.
  public let permission = ToolPermission.none
  /// True: calculations share no mutable state.
  public let isParallelSafe = true
  /// Advertises cancellation support to the executor for bounded expression evaluation.
  public let isCancellable = true

  /// Creates a stateless arithmetic tool.
  public init() {}

  /// Evaluates the expression and returns numeric structure and readable text.
  /// An unparseable expression produces an empty result; a missing expression throws invalidArguments.
  public func execute(arguments: ToolArguments) async throws -> ToolResult {
    guard let expression = arguments.string("expression") else {
      throw AgentError.invalidArguments(
        tool: name, violations: [.missingRequired(path: "expression")])
    }
    guard let value = Arithmetic.evaluate(expression) else {
      return ToolResult(
        callID: "", toolName: name, text: "Could not evaluate \"\(expression)\".", isEmpty: true)
    }
    return ToolResult(
      callID: "", toolName: name, text: Self.format(value), structured: .double(value))
  }

  private static func format(_ value: Double) -> String {
    value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
  }
}
