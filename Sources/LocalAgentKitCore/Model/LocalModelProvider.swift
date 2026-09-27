/// Why the model declined for policy reasons. Terminal: retrying a refusal burns battery and
/// context to fail identically (R3), so callers fall back to a non-agentic path instead.
public struct GuardrailRefusal: Sendable, Hashable, Codable {
  /// The model's own explanation, when the platform provides one.
  public var explanation: String?

  public init(explanation: String? = nil) {
    self.explanation = explanation
  }
}

public struct ModelMessage: Sendable, Hashable {
  public enum Role: Sendable, Hashable {
    case system, user, assistant, tool
  }

  public var role: Role
  public var content: String
  /// Calls the assistant made in this message (`.assistant` only).
  public var toolCalls: [ToolCall]
  /// The call this message answers (`.tool` only).
  public var toolCallID: String?

  public init(
    role: Role, content: String, toolCalls: [ToolCall] = [], toolCallID: String? = nil
  ) {
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
  }
}

/// One model call. The runtime assembles it after `ContextBudgeter` has fitted it to the window.
public struct ModelRequest: Sendable, Hashable {
  public var messages: [ModelMessage]
  public var tools: [ToolDescriptor]

  public init(messages: [ModelMessage], tools: [ToolDescriptor] = []) {
    self.messages = messages
    self.tools = tools
  }
}

/// What the model decided (FR-005). Distinguishes an answer from a tool request, a question
/// back to the user, and a policy refusal — never inferred from free-form text.
public enum ModelResponse: Sendable, Hashable {
  case text(String)
  case toolCall(ToolCall)
  case multipleToolCalls([ToolCall])
  case clarification(String)
  case refused(GuardrailRefusal)
}

/// The model seam (FR-004). Kept as Core's abstraction, per decision 0004, for testability and to
/// absorb per-OS quirks in the provider rather than the runtime.
///
/// Core must not import a model framework; conformances live in `LocalAgentKitProviders`.
public protocol LocalModelProvider: Sendable {
  /// True if inference needs the network. `NetworkPolicy.never` rejects such a provider at
  /// construction (FR-023). Defaults to false, the on-device case.
  var requiresNetwork: Bool { get }

  /// The context window in tokens, if the provider knows it. `ContextBudgeter` budgets against it.
  var contextWindowTokens: Int? { get }

  /// Counts tokens for the given messages, if the platform exposes a counter (findings §3).
  /// Returns nil when it cannot, and the budgeter falls back to an estimate.
  func tokenCount(for messages: [ModelMessage]) async -> Int?

  /// Honors `Task` cancellation. Throws ``AgentError`` — a provider maps platform errors itself.
  func generate(request: ModelRequest) async throws -> ModelResponse
}

extension LocalModelProvider {
  public var requiresNetwork: Bool { false }
  public var contextWindowTokens: Int? { nil }
  public func tokenCount(for messages: [ModelMessage]) async -> Int? { nil }
}
