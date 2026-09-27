import Foundation
import LocalAgentKitCore

/// Asks the model one narrow question whose answer must satisfy a schema.
///
/// The question is a synthetic tool, so a closed choice is a required parameter with
/// `allowedValues`, and everything the runtime already does for tool calls applies: schema
/// validation, then bounded repair with feedback (findings §11). Single-call accuracy is 51–63%,
/// so no answer is trusted until it validates.
struct ModelQuery: Sendable {
  let model: any LocalModelProvider
  let repairer: ArgumentRepairer

  /// - Throws: `.invalidArguments` if no valid answer arrives within the repair bound;
  ///   `.guardrailRefusal` if the model refuses, which is terminal and never retried (R3).
  func ask(_ descriptor: ToolDescriptor, messages: [ModelMessage]) async throws -> ToolArguments {
    let response = try await model.generate(
      request: ModelRequest(messages: messages, tools: [descriptor]))
    var candidate = ToolCall(id: "query", name: descriptor.name)
    switch response {
    case .toolCall(let call) where call.name == descriptor.name:
      candidate = call
    case .multipleToolCalls(let calls):
      if let call = calls.first(where: { $0.name == descriptor.name }) { candidate = call }
    case .refused(let refusal):
      throw AgentError.guardrailRefusal(refusal)
    case .text(let text), .clarification(let text):
      if let answer = Self.salvage(text, for: descriptor) { return answer }
    case .toolCall:
      break
    }
    let violations = descriptor.schema.validate(candidate.arguments)
    if violations.isEmpty { return candidate.arguments }
    return try await repairer.repair(
      candidate, violations: violations, descriptor: descriptor, history: messages, model: model
    ).arguments
  }

  /// A closed choice answered in plain text is still an answer, if it is exactly one of the
  /// options. Anything looser is not guessed at.
  static func salvage(_ text: String, for descriptor: ToolDescriptor) -> ToolArguments? {
    guard descriptor.schema.parameters.count == 1,
      let (name, parameter) = descriptor.schema.parameters.first,
      case .string = parameter.type, let allowed = parameter.allowedValues
    else { return nil }
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
      .lowercased()
    guard let match = allowed.first(where: { $0.lowercased() == cleaned }) else { return nil }
    return ToolArguments([name: .string(match)])
  }
}
