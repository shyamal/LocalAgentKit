import LocalAgentKitCore

/// Converts a supplied Celsius value without reading or modifying user data.
public struct TemperatureTool: AgentTool {
  public let name = "convert_temperature"
  public let description = "Convert Celsius to Fahrenheit. Use only for temperature conversion."
  public let permission = ToolPermission.none
  public let isParallelSafe = true
  public let isCancellable = true
  public let schema = ToolSchema(
    parameters: [
      "celsius": ToolParameter(
        .number, description: "Temperature in degrees Celsius, from -273.15 to 1000.",
        minimum: -273.15, maximum: 1000)
    ], required: ["celsius"])

  public init() {}

  public func execute(arguments: ToolArguments) async throws -> ToolResult {
    if Task.isCancelled { throw AgentError.cancelled }
    let violations = schema.validate(arguments)
    guard violations.isEmpty, let celsius = arguments.double("celsius") else {
      throw AgentError.invalidArguments(tool: name, violations: violations)
    }
    let fahrenheit = celsius * 9 / 5 + 32
    return ToolResult(
      callID: "", toolName: name, text: "\(fahrenheit) degrees Fahrenheit",
      structured: .double(fahrenheit))
  }
}
