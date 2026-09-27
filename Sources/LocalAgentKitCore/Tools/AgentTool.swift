/// A model-requested invocation of a tool.
public struct ToolCall: Sendable, Hashable, Codable, Identifiable {
  /// Correlates a call with its result. The provider supplies it; iOS 27 rejects transcripts whose
  /// tool outputs do not carry their call's id (findings §10).
  public var id: String
  public var name: String
  public var arguments: ToolArguments

  public init(id: String, name: String, arguments: ToolArguments = ToolArguments()) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

/// What a tool returned.
public struct ToolResult: Sendable, Hashable, Codable {
  public var callID: String
  public var toolName: String
  /// The text the model sees as the observation.
  public var text: String
  public var structured: JSONValue?
  /// True when the tool ran but reports failure or found nothing. The runtime's deterministic
  /// recovery (M1-RT-17) keys off this rather than off a thrown error.
  public var isEmpty: Bool

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
  public var call: ToolCall
  public var result: ToolResult

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
  var description: String { get }
  var schema: ToolSchema { get }
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
  public var name: String
  public var description: String
  public var schema: ToolSchema
  public var permission: ToolPermission
  public var isParallelSafe: Bool
  public var isCancellable: Bool

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

  public init(_ tool: some AgentTool) {
    self.init(
      name: tool.name, description: tool.description, schema: tool.schema,
      permission: tool.permission, isParallelSafe: tool.isParallelSafe,
      isCancellable: tool.isCancellable)
  }
}
