import LocalAgentKitCore

/// A configurable tool that records the arguments it is executed with. Tests use it to assert
/// that a call reached — or was stopped before — execution.
public actor MockTool: AgentTool {
  public typealias Handler = @Sendable (ToolArguments) async throws -> String

  public nonisolated let name: String
  public nonisolated let description: String
  public nonisolated let schema: ToolSchema
  public nonisolated let permission: ToolPermission
  public nonisolated let isParallelSafe: Bool
  public nonisolated let isCancellable: Bool
  private let handler: Handler
  private var executed: [ToolArguments] = []

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

  public func execute(arguments: ToolArguments) async throws -> ToolResult {
    executed.append(arguments)
    let text = try await handler(arguments)
    return ToolResult(callID: "", toolName: name, text: text)
  }
}
