import LocalAgentKitCore

/// Mathematical operations (FR-008). `.none`: pure computation, no side effects, no personal data.
public struct CalculatorTool: AgentTool {
  public let name = "calculate"
  public let description =
    "Evaluate an arithmetic expression and return the numeric result. Use for any math: "
    + "percentages, splitting amounts, unit rates."
  public let schema = ToolSchema(
    parameters: [
      "expression": ToolParameter(
        .string, description: "An arithmetic expression using numbers, + - * / and parentheses.")
    ], required: ["expression"])
  public let permission = ToolPermission.none
  public let isParallelSafe = true
  public let isCancellable = true

  public init() {}

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
