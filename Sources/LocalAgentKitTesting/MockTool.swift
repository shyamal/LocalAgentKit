import LocalAgentKitCore

/// A configurable tool that records the arguments it is executed with. Tests use it to assert
/// that a call reached — or was stopped before — execution.
public actor MockTool: AgentTool {
  /// Asynchronous execution handler returning observation text or throwing a test error.
  public typealias Handler = @Sendable (ToolArguments) async throws -> String

  /// Registered name advertised by the mock.
  public nonisolated let name: String
  /// Prompt-facing description advertised by the mock.
  public nonisolated let description: String
  /// Argument schema enforced when the mock is called through the executor.
  public nonisolated let schema: ToolSchema
  /// Fixed tier used to exercise runtime authorization behavior.
  public nonisolated let permission: ToolPermission
  /// Advertised parallel-execution capability, configurable for scheduling tests.
  public nonisolated let isParallelSafe: Bool
  /// Advertised cancellation capability; the supplied handler must honor this declaration.
  public nonisolated let isCancellable: Bool
  private let handler: Handler
  private var executed: [ToolArguments] = []

  /// Creates a recording tool with configurable metadata and execution behavior.
  /// Defaults describe a pure parallel-safe tool; supply a cancellation-aware handler when needed.
  public init(
    name: String = "mock_tool",
    description: String = "A mock tool.",
    schema: ToolSchema = .empty,
    permission: ToolPermission = .none,
    isParallelSafe: Bool = true,
    isCancellable: Bool = true,
    handler: @escaping Handler = { _ in "ok" }
  ) {
    self.name = name
    self.description = description
    self.schema = schema
    self.permission = permission
    self.isParallelSafe = isParallelSafe
    self.isCancellable = isCancellable
    self.handler = handler
  }

  /// Arguments of every execution, oldest first. Empty means the tool never ran.
  public var executions: [ToolArguments] { executed }

  /// Records arguments then invokes the handler and wraps its text as a tool result.
  /// Direct calls bypass runtime validation and permission checks.
  public func execute(arguments: ToolArguments) async throws -> ToolResult {
    executed.append(arguments)
    let text = try await handler(arguments)
    return ToolResult(callID: "", toolName: name, text: text)
  }
}
