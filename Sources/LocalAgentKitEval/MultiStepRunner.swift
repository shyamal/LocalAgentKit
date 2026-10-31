import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTools

/// One default-planner run with fixture tools, never the user's real device tools.
public struct MultiStepResult: Codable, Sendable {
  public let goalID: String
  public let repetition: Int
  public let calls: [MultiStepCall]
  public let score: MultiStepScore
  public let answer: String?
  public let stopReason: String
  public let error: String?
  public let runtimeIterations: Int?
  public let confirmationsApproved: Int
  public let elapsedSeconds: Double
}

/// Executes the fixed multi-step suite in StateMachinePlanner open mode. Expected steps and
/// matcher values are available to routing/scoring only, not injected into model prompts.
public enum MultiStepRunner {
  public static func run(
    model: any LocalModelProvider, repetitions: Int = 1,
    limit: Int? = nil, goalID: String? = nil, timeout: Duration = .seconds(60)
  ) async throws -> [MultiStepResult] {
    guard (1...100).contains(repetitions), timeout > .zero, limit.map({ $0 > 0 }) ?? true else {
      throw ProbeError.invalidOptions(
        "Repetitions must be 1...100; timeout and limit must be positive.")
    }
    let suite = try SuiteLoader.suite(named: "multi-step")
    guard let context = suite.context,
      let reference = GoalMatcher.parse(context.referenceDateTime, format: "yyyy-MM-dd'T'HH:mm"),
      let zone = TimeZone(identifier: context.timeZone), context.timeZone == "UTC"
    else { throw ProbeError.invalidOptions("Multi-step suite needs a fixed UTC clock.") }
    let catalog = try SuiteLoader.tools()
    var goals = suite.goals ?? []
    if let goalID {
      goals = goals.filter { $0.id == goalID }
      guard !goals.isEmpty else { throw ProbeError.invalidOptions("Unknown goal '\(goalID)'.") }
    }
    if let limit { goals = Array(goals.prefix(limit)) }
    var results: [MultiStepResult] = []
    for goal in goals {
      guard let maxCalls = goal.maxIterations, maxCalls > 0, !(goal.steps ?? []).isEmpty else {
        throw ProbeError.invalidOptions("Goal \(goal.id) has no steps or call bound.")
      }
      // Validate fixture and scorer setup before any generation or synthetic execution.
      for fixture in goal.fixtures ?? [] {
        for matcher in fixture.when.values { try matcher.validate() }
      }
      _ = try await MultiStepScorer.score(goal: goal, calls: [], tools: catalog, answered: false)
      let tools = try catalog.map { spec in
        FixtureTool(
          descriptor: try ProbeRunner.descriptor(spec), fixtures: goal.fixtures ?? [],
          defaultResult: suite.defaultToolResult ?? "No results found.")
      }
      for repetition in 1...repetitions {
        try Task.checkCancellation()
        let gate = FixtureGate()
        let runtime = try AgentRuntime(
          configuration: AgentConfiguration(
            model: model,
            limits: ExecutionLimits(
              maxIterations: maxCalls + 1, maxToolCalls: maxCalls,
              maxDuration: timeout, maxModelCallDuration: timeout), networkPolicy: .never),
          tools: StaticToolSource(tools), gate: gate, timeZone: zone, now: { reference })
        let stream = await runtime.events()
        let observer = Task { await collect(stream, runtime: runtime) }
        let start = ContinuousClock.now
        var response: AgentResponse?
        var failure: AgentError?
        do { response = try await runtime.run(goal.goal) } catch let error as AgentError {
          failure = error
        }
        await runtime.finishEvents()
        let observed = await observer.value
        if Task.isCancelled || (failure == .cancelled && !observed.clarification) {
          throw CancellationError()
        }
        let score = try await MultiStepScorer.score(
          goal: goal, calls: observed.calls, tools: catalog,
          answered: response != nil)
        let duration = start.duration(to: .now).components
        let reason: String
        if observed.clarification {
          reason = "clarification"
        } else if let failure {
          switch failure {
          case .maximumIterationsReached, .maximumToolCallsReached: reason = "limit"
          case .executionTimeout: reason = "timeout"
          case .guardrailRefusal: reason = "refused"
          case .loopDetected: reason = "loop"
          case .modelUnavailable: reason = "modelUnavailable"
          default: reason = "error"
          }
        } else {
          reason = "answer"
        }
        results.append(
          MultiStepResult(
            goalID: goal.id, repetition: repetition, calls: observed.calls,
            score: score, answer: response?.text, stopReason: reason,
            error: failure.map { String(describing: $0) }, runtimeIterations: response?.iterations,
            confirmationsApproved: await gate.approvals,
            elapsedSeconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18))
      }
    }
    return results
  }

  private struct Observed: Sendable {
    let calls: [MultiStepCall]
    let clarification: Bool
  }
  private static func collect(_ stream: AsyncStream<AgentEvent>, runtime: AgentRuntime) async
    -> Observed
  {
    var requested: [ToolCall] = []
    var completed: [Int: String] = [:]
    var started: [String: Int] = [:]
    var clarification = false
    for await event in stream {
      switch event {
      case .toolRequested(let call): requested.append(call)
      case .toolStarted(let call):
        if let index = requested.lastIndex(of: call) { started[call.id] = index }
      case .toolCompleted(let result):
        if let index = started[result.callID] { completed[index] = result.text }
      case .clarificationRequested:
        clarification = true
        // There is no person in an unattended benchmark. Do not fabricate their answer.
        await runtime.cancelCurrentRun()
      default: break
      }
    }
    return Observed(
      calls: requested.enumerated().map { index, call in
        MultiStepCall(
          name: call.name, arguments: call.arguments.values,
          completed: completed[index] != nil, output: completed[index])
      }, clarification: clarification)
  }
}

/// This gate is private to a runner that constructs ONLY fixture tools. It cannot approve any
/// real Calendar/Reminders/Notes tool supplied by the caller.
private actor FixtureGate: PermissionGate {
  private(set) var approvals = 0
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
    approvals += 1
    return .approved
  }
}

private struct FixtureTool: AgentTool {
  let descriptor: ToolDescriptor
  let fixtures: [SuiteLoader.Suite.Fixture]
  let defaultResult: String
  var name: String { descriptor.name }
  var description: String { descriptor.description }
  var schema: ToolSchema { descriptor.schema }
  var permission: ToolPermission { descriptor.permission }
  let isParallelSafe = true
  let isCancellable = true

  func execute(arguments: ToolArguments) async throws -> ToolResult {
    try Task.checkCancellation()
    if name == "calculate" { return try await CalculatorTool().execute(arguments: arguments) }
    for fixture in fixtures where fixture.tool == name {
      if try await GoalMatcher.all(fixture.when, arguments: arguments.values) {
        return ToolResult(
          callID: "", toolName: name, text: fixture.returns,
          isEmpty: fixture.returns == defaultResult)
      }
    }
    return ToolResult(callID: "", toolName: name, text: defaultResult, isEmpty: true)
  }
}
