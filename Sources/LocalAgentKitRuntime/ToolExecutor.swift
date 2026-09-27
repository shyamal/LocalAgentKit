import LocalAgentKitCore

/// Where the executor finds tools. `ToolRegistry` (in `LocalAgentKitTools`) conforms; Runtime
/// cannot depend on it, so it depends on this.
public protocol ToolSource: Sendable {
  func tool(named name: String) async -> (any AgentTool)?
  func descriptors() async -> [ToolDescriptor]
}

/// A fixed set of tools.
public struct StaticToolSource: ToolSource {
  private let tools: [String: any AgentTool]

  public init(_ tools: [any AgentTool]) {
    self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
  }

  public func tool(named name: String) async -> (any AgentTool)? { tools[name] }

  public func descriptors() async -> [ToolDescriptor] {
    tools.values.map { ToolDescriptor($0) }.sorted { $0.name < $1.name }
  }
}

public enum PermissionDecision: Sendable, Hashable {
  case approved
  case denied
}

/// Asks a human whether a tool may run. Suspends until they answer, holding no thread or lock.
///
/// The executor consults it **only** for tiers above `.readOnly`, so a gate cannot widen what runs
/// unconfirmed, and it cannot be used to skip a confirmation.
public protocol PermissionGate: Sendable {
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision
}

/// Runs one tool call: validate arguments, then the permission gate, then execute, then observe.
///
/// **The order is the security model.** A schema-valid call produced by text injected into an
/// ingested document reaches the gate and stops there; structured tool calls are not the defense
/// (PRD §19). Do not reorder these steps.
public struct ToolExecutor: Sendable {
  private let source: any ToolSource
  private let gate: (any PermissionGate)?
  private let events: EventBus

  /// - Parameter gate: With nil, every tool above `.readOnly` is denied.
  public init(source: any ToolSource, gate: (any PermissionGate)? = nil, events: EventBus) {
    self.source = source
    self.gate = gate
    self.events = events
  }

  /// - Throws: ``AgentError`` — `.toolNotFound`, `.invalidArguments`, `.permissionDenied`,
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
    if tool.permission.requiresConfirmation {
      await events.publish(.permissionRequired(call))
      let decision = await gate?.decide(for: call, tool: ToolDescriptor(tool)) ?? .denied
      try Task.checkCancellationAsAgentError()
      guard decision == .approved else {
        throw AgentError.permissionDenied(tool: call.name)
      }
    }

    // 3. Execute.
    await events.publish(.toolStarted(call))
    var result: ToolResult
    do {
      try Task.checkCancellationAsAgentError()
      result = try await tool.execute(arguments: call.arguments)
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
