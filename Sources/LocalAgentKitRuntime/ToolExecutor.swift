import LocalAgentKitCore

/// Where the executor finds tools. `ToolRegistry` (in `LocalAgentKitTools`) conforms; Runtime
/// cannot depend on it, so it depends on this.
public protocol ToolSource: Sendable {
  /// Looks up an executable tool by its registered name, returning nil when absent.
  func tool(named name: String) async -> (any AgentTool)?
  /// Returns the advertised contracts of available tools.
  func descriptors() async -> [ToolDescriptor]
}

/// A fixed set of tools.
public struct StaticToolSource: ToolSource {
  private let tools: [String: any AgentTool]

  /// Creates a fixed source; a duplicate name keeps the last supplied tool.
  public init(_ tools: [any AgentTool]) {
    self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
  }

  /// Looks up a tool from the fixed registration table.
  public func tool(named name: String) async -> (any AgentTool)? { tools[name] }

  /// Returns descriptors sorted by registered tool name.
  public func descriptors() async -> [ToolDescriptor] {
    tools.values.map { ToolDescriptor($0) }.sorted { $0.name < $1.name }
  }
}

/// The result of a required human confirmation.
public enum PermissionDecision: Sendable, Hashable {
  /// The requested operation may proceed.
  case approved
  /// The requested operation must not execute.
  case denied
}

/// Asks a human whether a tool may run. Suspends until they answer, holding no thread or lock.
///
/// The executor consults it **only** for tiers above `.readOnly`, so a gate cannot widen what runs
/// unconfirmed, and it cannot be used to skip a confirmation.
public protocol PermissionGate: Sendable {
  /// Obtains a human decision for a call whose tier requires confirmation.
  /// Implementations should suspend without holding a thread and respect cancellation.
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision
}

/// Runs one tool call: validate arguments, then the permission gate, then execute, then observe.
///
/// **The order is the security model.** A schema-valid call produced by text injected into an
/// ingested document reaches the gate and stops there; structured tool calls are not the defense
/// (PRD §19). Do not reorder these steps.
public struct ToolExecutor: Sendable {
  private let source: any ToolSource
  private let permissions: PermissionManager
  private let events: EventBus
  private let remainingTime: (@Sendable () async -> Duration)?
  private let auditLogger: AuditLogger?

  /// - Parameters:
  ///   - source: Resolves registered tool implementations.
  ///   - events: Publishes requests, permission decisions, and execution outcomes.
  ///   - gate: With nil, every tool above `.readOnly` is denied.
  ///   - remainingTime: How long the run has left. A tool that declares `isCancellable` is
  ///     abandoned when it runs out; one that does not is left to finish, since it cannot be
  ///     stopped safely.
  ///   - auditLogger: Records every confirmed (above `.readOnly`) execution (M1-SE-02). Nil
  ///     disables the log; `AgentRuntime` decides based on `SecurityPolicy.auditSensitiveExecutions`.
  public init(
    source: any ToolSource, gate: (any PermissionGate)? = nil, events: EventBus,
    remainingTime: (@Sendable () async -> Duration)? = nil, auditLogger: AuditLogger? = nil
  ) {
    self.source = source
    self.permissions = PermissionManager(gate: gate)
    self.events = events
    self.remainingTime = remainingTime
    self.auditLogger = auditLogger
  }

  /// - Throws: `LocalAgentKitCore.AgentError` — `.toolNotFound`, `.invalidArguments`, `.permissionDenied`,
  ///   `.toolFailed`, or `.cancelled`. An invalid-arguments failure is repairable
  ///   (see ``ArgumentRepairer``); a denial is final.
  public func execute(_ call: ToolCall) async throws -> ToolObservation {
    await events.publish(.toolRequested(call))
    guard let tool = await source.tool(named: call.name) else {
      throw AgentError.toolNotFound(name: call.name)
    }

    // 1. Validate.
    let violations = tool.schema.validate(call.arguments)
    guard violations.isEmpty else {
      throw AgentError.invalidArguments(tool: call.name, violations: violations)
    }

    // 2. Permission gate.
    let descriptor = ToolDescriptor(tool)
    if tool.permission.requiresConfirmation {
      await events.publish(.permissionRequired(call))
    }
    let decision = await permissions.authorize(call, tool: descriptor)
    try Task.checkCancellationAsAgentError()
    guard decision == .approved else {
      throw AgentError.permissionDenied(tool: call.name)
    }

    // 3. Execute.
    await events.publish(.toolStarted(call))
    var result: ToolResult
    do {
      try Task.checkCancellationAsAgentError()
      if tool.isCancellable, let remaining = await remainingTime?() {
        guard remaining > .zero else { throw AgentError.executionTimeout(.run) }
        result = try await withDeadline(remaining, scope: .run) {
          try await tool.execute(arguments: call.arguments)
        }
      } else {
        result = try await tool.execute(arguments: call.arguments)
      }
    } catch let error as AgentError {
      throw error
    } catch is CancellationError {
      throw AgentError.cancelled
    } catch {
      throw AgentError.toolFailed(tool: call.name, message: String(describing: error))
    }
    // The call id must travel with the result: iOS 27 rejects a transcript whose tool output does
    // not carry it (findings §10).
    result.callID = call.id
    result.toolName = call.name
    await events.publish(.toolCompleted(result))
    if tool.permission.requiresConfirmation {
      await auditLogger?.record(
        AuditEntry(
          toolName: call.name, permission: tool.permission,
          argumentsSignature: call.arguments.signature, wasEmpty: result.isEmpty))
    }

    // 4. Observe.
    let observation = ToolObservation(call: call, result: result)
    await events.publish(.observationReceived(observation))
    return observation
  }
}

extension Task where Success == Never, Failure == Never {
  fileprivate static func checkCancellationAsAgentError() throws {
    if Task.isCancelled { throw AgentError.cancelled }
  }
}
