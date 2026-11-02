/// A model-requested invocation of a tool.
public struct ToolCall: Sendable, Hashable, Codable, Identifiable {
  /// Correlates a call with its result. The provider supplies it; iOS 27 rejects transcripts whose
  /// tool outputs do not carry their call's id (findings §10).
  public var id: String
  /// Registered tool name the invocation targets.
  public var name: String
  /// Model-produced argument values, validated before execution.
  public var arguments: ToolArguments

  /// Creates an invocation with a correlation ID, registered name and optional arguments.
  public init(id: String, name: String, arguments: ToolArguments = ToolArguments()) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

/// What a tool returned.
public struct ToolResult: Sendable, Hashable, Codable {
  /// Invocation identifier; the executor fills it from the original call.
  public var callID: String
  /// Registered name of the tool that produced this result.
  public var toolName: String
  /// The text the model sees as the observation.
  public var text: String
  /// Optional machine-readable observation used for workflow bindings.
  public var structured: JSONValue?
  /// True when the tool ran but reports failure or found nothing. The runtime's deterministic
  /// recovery (M1-RT-17) keys off this rather than off a thrown error.
  public var isEmpty: Bool

  /// Creates a compact observation with optional structured output and an empty-result flag.
  public init(
    callID: String, toolName: String, text: String, structured: JSONValue? = nil,
    isEmpty: Bool = false
  ) {
    self.callID = callID
    self.toolName = toolName
    self.text = text
    self.structured = structured
    self.isEmpty = isEmpty
  }
}

/// A completed call together with its result — one turn of the observe step.
public struct ToolObservation: Sendable, Hashable {
  /// The invocation that was executed.
  public var call: ToolCall
  /// Its correlated result, including text and optional structure.
  public var result: ToolResult

  /// Pairs a tool invocation with its completed result.
  public init(call: ToolCall, result: ToolResult) {
    self.call = call
    self.result = result
  }
}

/// A capability the agent can invoke (FR-006).
///
/// Conformers must declare `isParallelSafe` and `isCancellable` honestly; neither has a default,
/// because the runtime cannot schedule parallel execution or propagate cancellation without them.
public protocol AgentTool: Sendable {
  /// `snake_case`, verb-first (`create_reminder`). The model reads this as a prompt.
  var name: String { get }
  /// Prompt-facing guidance on when and how to choose this capability.
  var description: String { get }
  /// Argument contract validated before permission checks and execution.
  var schema: ToolSchema { get }
  /// Fixed authorization tier enforced by the executor; never downgrade it dynamically.
  var permission: ToolPermission { get }
  /// True only if concurrent invocations cannot interfere with each other.
  var isParallelSafe: Bool { get }
  /// True only if `execute` responds to `Task` cancellation promptly.
  var isCancellable: Bool { get }

  /// `arguments` have already passed schema validation and the permission gate.
  func execute(arguments: ToolArguments) async throws -> ToolResult
}

/// What the model is told about a tool. Carries no executable code.
public struct ToolDescriptor: Sendable, Hashable {
  /// Unique registered tool name shown to the model.
  public var name: String
  /// Prompt-facing guidance for choosing the tool.
  public var description: String
  /// The argument contract exposed to the model.
  public var schema: ToolSchema
  /// Fixed authorization tier of the executable tool.
  public var permission: ToolPermission
  /// Whether concurrent executions of the underlying tool can safely coexist.
  public var isParallelSafe: Bool
  /// Whether the underlying execution can honor task cancellation.
  public var isCancellable: Bool

  /// Creates a descriptor without executable code from explicit tool metadata.
  public init(
    name: String, description: String, schema: ToolSchema, permission: ToolPermission,
    isParallelSafe: Bool, isCancellable: Bool
  ) {
    self.name = name
    self.description = description
    self.schema = schema
    self.permission = permission
    self.isParallelSafe = isParallelSafe
    self.isCancellable = isCancellable
  }

  /// Copies the advertised contract from an executable tool.
  public init(_ tool: some AgentTool) {
    self.init(
      name: tool.name, description: tool.description, schema: tool.schema,
      permission: tool.permission, isParallelSafe: tool.isParallelSafe,
      isCancellable: tool.isCancellable)
  }
}
