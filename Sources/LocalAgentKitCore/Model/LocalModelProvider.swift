/// Why the model declined for policy reasons. Terminal: retrying a refusal burns battery and
/// context to fail identically (R3), so callers fall back to a non-agentic path instead.
public struct GuardrailRefusal: Sendable, Hashable, Codable {
  /// The model's own explanation, when the platform provides one.
  public var explanation: String?

  /// Creates a terminal refusal with an optional platform-provided explanation.
  public init(explanation: String? = nil) {
    self.explanation = explanation
  }
}

/// One transcript entry, with role and optional tool-call correlation.
public struct ModelMessage: Sendable, Hashable {
  /// The participant or instruction channel that produced a transcript entry.
  public enum Role: Sendable, Hashable {
    /// Instructions establishing behavior for subsequent entries.
    case system
    /// Input from the person requesting work.
    case user
    /// Model output, including any tool calls.
    case assistant
    /// The observation returned by a prior tool call.
    case tool
  }

  /// The transcript channel for this entry.
  public var role: Role
  /// Text carried by this entry; tool correlation is stored separately.
  public var content: String
  /// Calls the assistant made in this message (`.assistant` only).
  public var toolCalls: [ToolCall]
  /// The call this message answers (`.tool` only).
  public var toolCallID: String?

  /// Creates a transcript entry; pair assistant tool calls with matching tool-result IDs.
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
  /// Ordered transcript entries supplied to the model.
  public var messages: [ModelMessage]
  /// Tool definitions available for this request; empty permits no declared tools.
  public var tools: [ToolDescriptor]

  /// Creates a request from a transcript and optional tool descriptors.
  public init(messages: [ModelMessage], tools: [ToolDescriptor] = []) {
    self.messages = messages
    self.tools = tools
  }
}

/// What the model decided (FR-005). Distinguishes an answer from a tool request, a question
/// back to the user, and a policy refusal — never inferred from free-form text.
public enum ModelResponse: Sendable, Hashable {
  /// A final or intermediate natural-language answer.
  case text(String)
  /// One tool invocation for the runtime to validate and authorize.
  case toolCall(ToolCall)
  /// Multiple requested invocations; runtime scheduling determines execution order.
  case multipleToolCalls([ToolCall])
  /// A question requiring human input before the goal can continue.
  case clarification(String)
  /// A terminal policy refusal, distinct from an execution failure.
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

  /// Counts tokens for a whole request, tool definitions included (they cost about a quarter of
  /// the window, findings §10), if the platform exposes a counter (findings §3). Returns nil when
  /// it cannot, and the budgeter falls back to an estimate.
  func tokenCount(for request: ModelRequest) async -> Int?

  /// Honors `Task` cancellation. Throws ``AgentError`` — a provider maps platform errors itself.
  func generate(request: ModelRequest) async throws -> ModelResponse
}

extension LocalModelProvider {
  /// Default for a provider that does not require network access.
  public var requiresNetwork: Bool { false }
  /// Unknown by default; the budgeter uses its configured fallback window.
  public var contextWindowTokens: Int? { nil }
  /// Returns nil by default so budgeting uses a conservative token estimate.
  public func tokenCount(for request: ModelRequest) async -> Int? { nil }
}
