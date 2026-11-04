import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime

/// Failures in harness setup, distinct from failures of the model being measured.
public enum ProbeError: Error, CustomStringConvertible {
  case invalidOptions(String)
  case unsupportedSuite(String)
  case invalidCatalog(String)

  public var description: String {
    switch self {
    case .invalidOptions(let reason): reason
    case .unsupportedSuite(let name):
      "Single-call probes support single-tool and refusal, not \(name)."
    case .invalidCatalog(let reason): "Invalid tool catalog: \(reason)"
    }
  }
}

/// Captures one model response without executing any returned tool calls.
public struct ProbeResult: Codable, Sendable {
  public enum Outcome: String, Codable, Sendable {
    case text, toolCalls, clarification, refused, failure
  }
  public struct Call: Codable, Sendable {
    public let name: String
    public let arguments: [String: JSONValue]
  }
  public let goalID: String
  public let repetition: Int
  public let outcome: Outcome
  public let text: String?
  public let calls: [Call]
  public let failureKind: String?
  public let error: String?
  public let elapsedSeconds: Double
}

/// Runs the durable single-call suites through the runtime's budget and deadline wrapper.
/// This is a probe of provider output, not an agent completion or tool execution benchmark.
public enum ProbeRunner {
  public static func run(
    suiteName: String, model: any LocalModelProvider,
    repetitions: Int = 1, limit: Int? = nil, goalID: String? = nil,
    timeout: Duration = .seconds(60)
  ) async throws -> [ProbeResult] {
    guard ["single-tool", "refusal", "notes-local", "contacts-local"].contains(suiteName) else {
      throw ProbeError.unsupportedSuite(suiteName)
    }
    guard (1...100).contains(repetitions), timeout > .zero, limit.map({ $0 > 0 }) ?? true else {
      throw ProbeError.invalidOptions(
        "Repetitions must be 1...100; timeout and limit must be positive.")
    }
    let suite = try SuiteLoader.suite(named: suiteName)
    var goals = suite.goals ?? []
    if let goalID {
      goals = goals.filter { $0.id == goalID }
      guard !goals.isEmpty else { throw ProbeError.invalidOptions("Unknown goal '\(goalID)'.") }
    }
    if let limit { goals = Array(goals.prefix(limit)) }
    let tools = try SuiteLoader.tools().map(descriptor)
    let clock = suite.context
    let instructions = """
      Now is \(clock?.referenceWeekday ?? "Monday") \(clock?.referenceDateTime ?? "2026-09-21T10:00").
      Time zone: \(clock?.timeZone ?? "UTC"); locale: \(clock?.locale ?? "en_US").
      Use the provided tools when needed. Return requested tool arguments; do not claim they executed.
      """
    var results: [ProbeResult] = []
    for goal in goals {
      for repetition in 1...repetitions {
        try Task.checkCancellation()
        let capture = Capture()
        let planner = ProbePlanner(instructions: instructions, descriptors: tools, capture: capture)
        let runtime = try AgentRuntime(
          configuration: AgentConfiguration(
            model: model,
            limits: ExecutionLimits(
              maxIterations: 1, maxToolCalls: 0,
              maxDuration: timeout, maxModelCallDuration: timeout), networkPolicy: .never),
          tools: StaticToolSource([]), planner: planner)
        let start = ContinuousClock.now
        var failure: AgentError?
        do {
          _ = try await runtime.run(goal.goal)
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as AgentError {
          if error == .cancelled { throw CancellationError() }
          failure = error
        }
        let duration = start.duration(to: .now).components
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        let response = await capture.response
        results.append(
          result(
            response, failure: failure, goalID: goal.id,
            repetition: repetition, elapsed: elapsed))
        await runtime.finishEvents()
      }
    }
    return results
  }

  static func descriptor(_ tool: SuiteLoader.Tool) throws -> ToolDescriptor {
    var parameters: [String: ToolParameter] = [:]
    for (name, argument) in tool.arguments {
      let type: ToolParameterType
      switch argument.type {
      case "string": type = .string
      case "integer": type = .integer
      case "number": type = .number
      case "boolean": type = .boolean
      default: throw ProbeError.invalidCatalog("unsupported type \(argument.type)")
      }
      var description = argument.description ?? name
      if let pattern = argument.pattern { description += " Whole-value pattern: \(pattern)." }
      parameters[name] = ToolParameter(
        type, description: description,
        allowedValues: argument.allowedValues)
    }
    let permission: ToolPermission
    switch tool.permission {
    case "none": permission = .none
    case "readOnly": permission = .readOnly
    case "userConfirmation": permission = .userConfirmation
    case "sensitive": permission = .sensitive
    case "destructive": permission = .destructive
    default: throw ProbeError.invalidCatalog("unknown permission \(tool.permission)")
    }
    return ToolDescriptor(
      name: tool.name, description: tool.description,
      schema: ToolSchema(
        parameters: parameters,
        required: Set(tool.arguments.filter { $0.value.required }.keys)),
      permission: permission, isParallelSafe: false, isCancellable: true)
  }

  private static func result(
    _ response: ModelResponse?, failure: AgentError?,
    goalID: String, repetition: Int, elapsed: Double
  ) -> ProbeResult {
    var outcome: ProbeResult.Outcome = .failure
    var text: String?
    var calls: [ToolCall] = []
    var failureKind: String?
    if let failure {
      switch failure {
      case .guardrailRefusal(let refusal):
        outcome = .refused
        text = refusal.explanation
      case .contextLimitExceeded: failureKind = "contextLimitExceeded"
      case .executionTimeout: failureKind = "timeout"
      case .modelUnavailable: failureKind = "modelUnavailable"
      default: failureKind = "other"
      }
    } else if let response {
      switch response {
      case .text(let value):
        outcome = .text
        text = value
      case .clarification(let value):
        outcome = .clarification
        text = value
      case .refused(let refusal):
        outcome = .refused
        text = refusal.explanation
      case .toolCall(let call):
        outcome = .toolCalls
        calls = [call]
      case .multipleToolCalls(let values):
        outcome = .toolCalls
        calls = values
      }
    }
    return ProbeResult(
      goalID: goalID, repetition: repetition, outcome: outcome, text: text,
      calls: calls.map { ProbeResult.Call(name: $0.name, arguments: $0.arguments.values) },
      failureKind: failureKind, error: failure.map { String(describing: $0) },
      elapsedSeconds: elapsed)
  }
}

private actor Capture {
  private(set) var response: ModelResponse?
  func record(_ response: ModelResponse) { self.response = response }
}

/// Returns the raw response to the recorder, then completes before ToolExecutor is entered.
private struct ProbePlanner: AgentPlanner {
  let instructions: String
  let descriptors: [ToolDescriptor]
  let capture: Capture

  func plan(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    async throws -> AgentPlan
  {
    AgentPlan(steps: [PlanStep(id: "probe", summary: "Capture one model response")])
  }

  func next(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    async throws -> PlannerDecision
  {
    let response = try await model.generate(
      request: ModelRequest(
        messages: [
          ModelMessage(role: .system, content: instructions),
          ModelMessage(role: .user, content: context.goal),
        ], tools: descriptors))
    await capture.record(response)
    return .complete("Probe captured; no tool executed.")
  }

  func observe(_ observation: ToolObservation, context: inout AgentContext) throws -> PlanRevision {
    .continue
  }
  func handleFailure(_ error: AgentError, context: inout AgentContext) throws -> PlanRevision {
    throw error
  }
}
