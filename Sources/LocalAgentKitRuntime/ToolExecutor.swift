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
  // Internal runtime admission check, performed after human permission and before side effects.
  var executionCheck: (@Sendable () async throws -> Void)?

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

    let descriptor = ToolDescriptor(tool)
    try validate(call, descriptor: descriptor)
    try await authorize(call, descriptor: descriptor)
    return try await executeAuthorized(call, tool: tool, descriptor: descriptor)
  }

  /// Runs explicitly independent ready calls, after validating and authorizing the whole batch.
  /// Confirmations are requested serially. At most four calls execute at once when every tool
  /// declares isParallelSafe; otherwise the entire batch executes serially. Results retain input
  /// order, while per-call events follow actual execution. A failure cancels sibling tasks;
  /// noncancellable work can delay cleanup. Completed side effects cannot be rolled back.
  /// Batch arguments are concrete and are never repaired by a model.
  public func executeBatch(_ calls: [ToolCall]) async throws -> [ToolObservation] {
    guard !calls.isEmpty, Set(calls.map(\.id)).count == calls.count,
      calls.allSatisfy({ !$0.id.isEmpty })
    else {
      throw AgentError.invalidArguments(
        tool: "tool_batch",
        violations: [.typeMismatch(path: "calls", expected: "nonempty calls with unique IDs")])
    }
    var ready: [(ToolCall, any AgentTool, ToolDescriptor)] = []
    for call in calls {
      try Task.checkCancellationAsAgentError()
      await events.publish(.toolRequested(call))
      guard let tool = await source.tool(named: call.name) else {
        throw AgentError.toolNotFound(name: call.name)
      }
      let descriptor = ToolDescriptor(tool)
      try validate(call, descriptor: descriptor)
      ready.append((call, tool, descriptor))
    }
    // Resolve each tool once. Execution uses these same contracts and implementations, even
    // if a dynamic source would return a different tool on the next lookup.
    for (call, _, descriptor) in ready { try await authorize(call, descriptor: descriptor) }
    if !ready.allSatisfy({ $0.2.isParallelSafe }) {
      var observations: [ToolObservation] = []
      for (call, tool, descriptor) in ready {
        observations.append(try await executeAuthorized(call, tool: tool, descriptor: descriptor))
      }
      return observations
    }
    return try await withThrowingTaskGroup(of: (Int, ToolObservation).self) { group in
      var next = 0
      var results: [Int: ToolObservation] = [:]
      func submit(_ index: Int) {
        let (call, tool, descriptor) = ready[index]
        group.addTask {
          (index, try await executeAuthorized(call, tool: tool, descriptor: descriptor))
        }
      }
      for index in 0..<min(4, ready.count) {
        submit(index)
        next += 1
      }
      do {
        while let (index, observation) = try await group.next() {
          results[index] = observation
          if next < ready.count {
            submit(next)
            next += 1
          }
        }
      } catch {
        group.cancelAll()
        throw error
      }
      try Task.checkCancellationAsAgentError()
      return ready.indices.compactMap { results[$0] }
    }
  }

  private func validate(_ call: ToolCall, descriptor: ToolDescriptor) throws {
    let violations = descriptor.schema.validate(call.arguments)
    guard violations.isEmpty else {
      throw AgentError.invalidArguments(tool: call.name, violations: violations)
    }
  }

  private func authorize(_ call: ToolCall, descriptor: ToolDescriptor) async throws {
    try Task.checkCancellationAsAgentError()
    if descriptor.permission.requiresConfirmation {
      await events.publish(.permissionRequired(call))
    }
    let decision = await permissions.authorize(call, tool: descriptor)
    try Task.checkCancellationAsAgentError()
    guard decision == .approved else { throw AgentError.permissionDenied(tool: call.name) }
  }

  private func executeAuthorized(
    _ call: ToolCall, tool: any AgentTool, descriptor: ToolDescriptor
  ) async throws -> ToolObservation {
    try Task.checkCancellationAsAgentError()
    // 3. Execute.
    try await executionCheck?()
    let remaining = await remainingTime?()
    if let remaining, remaining <= .zero { throw AgentError.executionTimeout(.run) }
    try Task.checkCancellationAsAgentError()
    await events.publish(.toolStarted(call))
    var result: ToolResult
    do {
      try Task.checkCancellationAsAgentError()
      if descriptor.isCancellable, let remaining {
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
    if descriptor.permission.requiresConfirmation {
      await auditLogger?.record(
        AuditEntry(
          toolName: call.name, permission: descriptor.permission,
          argumentsSignature: call.arguments.signature, wasEmpty: result.isEmpty))
    }

    // Record confirmed completed side effects even if cancellation arrived during work.
    // Suppress their late success events/facts after cancellation.
    try Task.checkCancellationAsAgentError()
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
