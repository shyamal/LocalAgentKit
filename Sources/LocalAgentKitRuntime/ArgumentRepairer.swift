import LocalAgentKitCore

/// The bounded repair path for invalid tool arguments (M1-RT-08): tell the model exactly what was
/// wrong and ask again, a limited number of times. Single-call accuracy on-device is 51–63%
/// (findings §11), so this path is expected to run.
public struct ArgumentRepairer: Sendable {
  /// Maximum extra model attempts after initial argument validation fails; clamped to zero or greater.
  public let maxAttempts: Int

  /// Creates an argument repair policy with a bounded number of extra attempts.
  public init(maxAttempts: Int = 2) {
    self.maxAttempts = max(0, maxAttempts)
  }

  /// Asks the model for a corrected call until it validates or attempts run out.
  ///
  /// - Parameters:
  ///   - call: The invalid call to repair.
  ///   - violations: Validation failures to present to the model.
  ///   - descriptor: The tool schema against which repairs are validated.
  ///   - model: The runtime-budgeted model used for repair requests.
  ///   - history: The conversation up to, and not including, the invalid call.
  /// - Returns: A call that passes `descriptor.schema`.
  /// - Throws: `.invalidArguments` when attempts are exhausted or the model stops calling the
  ///   tool; `.guardrailRefusal` if it refuses (never retried); any provider error.
  public func repair(
    _ call: ToolCall,
    violations: [ArgumentViolation],
    descriptor: ToolDescriptor,
    history: [ModelMessage],
    model: any LocalModelProvider
  ) async throws -> ToolCall {
    var current = call
    var currentViolations = violations
    var messages = history
    for _ in 0..<maxAttempts {
      messages.append(ModelMessage(role: .assistant, content: "", toolCalls: [current]))
      messages.append(
        ModelMessage(
          role: .tool, content: Self.feedback(for: currentViolations), toolCallID: current.id))
      let response = try await model.generate(
        request: ModelRequest(messages: messages, tools: [descriptor]))
      switch response {
      case .toolCall(let next) where next.name == descriptor.name:
        current = next
        currentViolations = descriptor.schema.validate(next.arguments)
        if currentViolations.isEmpty { return current }
      case .refused(let refusal):
        throw AgentError.guardrailRefusal(refusal)
      default:
        throw AgentError.invalidArguments(tool: descriptor.name, violations: currentViolations)
      }
    }
    throw AgentError.invalidArguments(tool: descriptor.name, violations: currentViolations)
  }

  static func feedback(for violations: [ArgumentViolation]) -> String {
    "The arguments were invalid: " + violations.map(\.description).joined(separator: "; ")
      + ". Call the tool again with corrected arguments."
  }
}
