import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime

/// Deterministic M8 evidence from synthetic tools and an intentionally repeating planner.
/// This verifies runtime admission, not a native model's probability of producing a loop.
public struct LoopVerificationReport: Codable, Sendable {
  public struct Trial: Codable, Sendable {
    public let scenario: String
    public let repetition: Int
    public let category: String
    public let expectedStop: String
    public let actualStop: String
    public let expectedExecutions: Int
    public let proposedCalls: Int
    public let requestedCalls: Int
    public let startedCalls: Int
    public let completedCalls: Int
    public let executedCalls: Int
    public let observations: Int
    public let approvals: Int
    public let terminalEvents: Int
    public let modelCalls: Int
    public let passed: Bool
  }
  public let schemaVersion: Int
  public let protocolVersion: Int
  public let synthetic: Bool
  public let scope: String
  public let operatingSystem: String
  public let createdAt: Date
  public let repetitions: Int
  public let trials: [Trial]
  public var passed: Bool { !trials.isEmpty && trials.allSatisfy { $0.passed } }
}

/// Runs fixed loop-inducing and negative-control scenarios through AgentRuntime.
public enum LoopVerification {
  private struct Scenario: Sendable {
    let id: String
    var category = "loop"
    let batches: [[ToolCall]]
    var policy = LoopDetectionConfiguration()
    var expectedStop = "loop:loop_a"
    let executions: Int
    var approvals = 0
    var maxIterations = 20
    var maxToolCalls = 32
  }

  /// Repeats each scenario on the same runtime to verify history resets between runs.
  /// No user tools, native model, permissions or network services are used.
  public static func run(repetitions: Int = 3) async throws -> LoopVerificationReport {
    guard (1...100).contains(repetitions) else {
      throw ProbeError.invalidOptions("Loop verification repetitions must be 1...100.")
    }
    var trials: [LoopVerificationReport.Trial] = []
    for scenario in scenarios() {
      try Task.checkCancellation()
      let model = UnusedLoopModel()
      let ledger = LoopProposalLedger()
      let tools = ["loop_a", "loop_b", "loop_c", "loop_d", "loop_write"].map {
        LoopFixtureTool(name: $0)
      }
      let gate = LoopFixtureGate()
      let runtime = try AgentRuntime(
        configuration: AgentConfiguration(
          model: model,
          limits: ExecutionLimits(
            maxIterations: scenario.maxIterations,
            maxToolCalls: scenario.maxToolCalls, maxDuration: .seconds(5)),
          loopDetection: scenario.policy), tools: StaticToolSource(tools),
        planner: LoopFixturePlanner(batches: scenario.batches, ledger: ledger), gate: gate)
      let stream = await runtime.events()
      let observer = Task { await evidence(stream) }
      var executionsByRun:
        [(stop: String, executions: Int, approvals: Int, proposals: Int, models: Int)] = []
      for _ in 1...repetitions {
        if Task.isCancelled {
          await runtime.finishEvents()
          _ = await observer.value
          throw CancellationError()
        }
        let beforeExecutions = await executionCount(tools)
        let beforeApprovals = await gate.count
        let beforeProposals = await ledger.count
        let beforeModels = await model.count
        var stop = "answer"
        do { _ = try await runtime.run("Synthetic loop verification") } catch let error
          as AgentError
        { stop = reason(error) }
        executionsByRun.append(
          (
            stop, await executionCount(tools) - beforeExecutions,
            await gate.count - beforeApprovals, await ledger.count - beforeProposals,
            await model.count - beforeModels
          ))
      }
      await runtime.finishEvents()
      let evidenceByRun = await observer.value
      try Task.checkCancellation()
      for (index, run) in executionsByRun.enumerated() {
        let observed = evidenceByRun.indices.contains(index) ? evidenceByRun[index] : Evidence()
        let passed =
          run.stop == scenario.expectedStop && observed.stop == run.stop
          && run.executions == scenario.executions && run.approvals == scenario.approvals
          && observed.requested == run.executions && observed.started == run.executions
          && observed.completed == run.executions && observed.observations == run.executions
          && observed.terminal == 1 && run.models == 0 && evidenceByRun.count == repetitions
        trials.append(
          .init(
            scenario: scenario.id, repetition: index + 1,
            category: scenario.category, expectedStop: scenario.expectedStop, actualStop: run.stop,
            expectedExecutions: scenario.executions, proposedCalls: run.proposals,
            requestedCalls: observed.requested, startedCalls: observed.started,
            completedCalls: observed.completed, executedCalls: run.executions,
            observations: observed.observations, approvals: run.approvals,
            terminalEvents: observed.terminal, modelCalls: run.models, passed: passed))
      }
    }
    return LoopVerificationReport(
      schemaVersion: 1, protocolVersion: 1, synthetic: true,
      scope: "M8 deterministic runtime admission; periods 1...3 and declared text equivalence",
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      createdAt: Date(), repetitions: repetitions, trials: trials)
  }

  private static func scenarios() -> [Scenario] {
    func call(_ tool: String = "loop_a", _ text: String = "same", page: JSONValue? = nil)
      -> ToolCall
    {
      var arguments: [String: JSONValue] = ["query": .string(text)]
      if let page { arguments["page"] = page }
      return ToolCall(id: "fixture", name: tool, arguments: ToolArguments(arguments))
    }
    func serial(_ calls: [ToolCall]) -> [[ToolCall]] { calls.map { [$0] } }
    let a = call()
    let b = call("loop_b")
    let c = call("loop_c")
    let d = call("loop_d")
    let textPolicy = LoopDetectionConfiguration(textRules: [
      .init(
        tool: "loop_a", argument: "query",
        equivalentPhrases: [
          ["budget notes", "notes about the budget", "budget meeting preparation"]
        ])
    ])
    let equivalent = [
      call("loop_a", "budget notes"), call("loop_a", "notes about the budget"),
      call("loop_a", "budget meeting preparation"),
    ]
    return [
      Scenario(id: "exact-period-one", batches: serial([a, a, a]), executions: 2),
      Scenario(id: "alternating-period-two", batches: serial([a, b, a, b, a]), executions: 4),
      Scenario(id: "period-three", batches: serial([a, b, c, a, b, c, a]), executions: 6),
      Scenario(
        id: "numeric-equivalence",
        batches: serial([
          call(page: 1), call(page: .double(1)), call(page: 1),
        ]), executions: 2),
      Scenario(
        id: "text-normalization",
        batches: serial([
          call("loop_a", " New Query "), call("loop_a", "new query"), call("loop_a", "NEW\nQUERY"),
        ]),
        policy: textPolicy, executions: 2),
      Scenario(
        id: "declared-paraphrases", batches: serial(equivalent), policy: textPolicy, executions: 2),
      Scenario(
        id: "semantic-alternation",
        batches: serial([equivalent[0], b, equivalent[1], b, equivalent[2]]),
        policy: textPolicy, executions: 4),
      Scenario(id: "whole-batch-exact", batches: [[a, a, a]], executions: 0),
      Scenario(
        id: "whole-batch-semantic", batches: [equivalent], policy: textPolicy, executions: 0),
      Scenario(id: "cross-batch-cycle", batches: [[a, b], [a, b, a]], executions: 2),
      Scenario(
        id: "confirmed-write-loop",
        batches: serial([call("loop_write"), call("loop_write"), call("loop_write")]),
        expectedStop: "loop:loop_write", executions: 2, approvals: 2),
      Scenario(
        id: "single-retry-control", category: "control", batches: serial([a, a]),
        expectedStop: "answer", executions: 2),
      Scenario(
        id: "changing-page-control", category: "control",
        batches: serial((1...6).map { call(page: .int($0)) }),
        policy: textPolicy, expectedStop: "answer", executions: 6),
      Scenario(
        id: "unknown-paraphrase-control", category: "control",
        batches: serial([
          call("loop_a", "read budget"), call("loop_a", "find spending"),
          call("loop_a", "locate estimates"),
        ]),
        policy: textPolicy, expectedStop: "answer", executions: 3),
      Scenario(
        id: "exact-policy-control", category: "control", batches: serial(equivalent),
        expectedStop: "answer", executions: 3),
      Scenario(
        id: "iteration-limit-before-detection", category: "boundary", batches: serial([a, a, a]),
        expectedStop: "iterationLimit", executions: 2, maxIterations: 2),
      Scenario(
        id: "outside-default-period", category: "boundary",
        batches: serial([a, b, c, d, a, b, c, d, a]),
        expectedStop: "toolLimit", executions: 8, maxToolCalls: 8),
    ]
  }

  private struct Evidence {
    var requested = 0, started = 0, completed = 0, observations = 0, terminal = 0
    var stop = "missingTerminal"
  }
  private static func evidence(_ events: AsyncStream<AgentEvent>) async -> [Evidence] {
    var runs: [Evidence] = []
    for await event in events {
      if case .started = event { runs.append(Evidence()) }
      guard let index = runs.indices.last else { continue }
      switch event {
      case .toolRequested: runs[index].requested += 1
      case .toolStarted: runs[index].started += 1
      case .toolCompleted: runs[index].completed += 1
      case .observationReceived: runs[index].observations += 1
      case .completed:
        runs[index].terminal += 1
        runs[index].stop = "answer"
      case .error(let error):
        runs[index].terminal += 1
        runs[index].stop = reason(error)
      case .guardrailRefused:
        runs[index].terminal += 1
        runs[index].stop = "refused"
      default: break
      }
    }
    return runs
  }
  private static func reason(_ error: AgentError) -> String {
    switch error {
    case .loopDetected(let tool): "loop:" + tool
    case .maximumIterationsReached: "iterationLimit"
    case .maximumToolCallsReached: "toolLimit"
    default: String(describing: error)
    }
  }
  private static func executionCount(_ tools: [LoopFixtureTool]) async -> Int {
    var count = 0
    for tool in tools { count += await tool.count }
    return count
  }
}

private actor LoopProposalLedger {
  var count = 0
  func record(_ calls: Int) { count += calls }
}
private struct LoopFixturePlanner: AgentPlanner {
  let batches: [[ToolCall]]
  let ledger: LoopProposalLedger
  func plan(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    -> AgentPlan
  { AgentPlan(steps: []) }
  func next(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    async -> PlannerDecision
  {
    let observed: Int
    if case .int(let count)? = context.workingMemory.value(for: "loop_fixture_count") {
      observed = count
    } else {
      observed = 0
    }
    var offset = 0
    for batch in batches {
      if offset == observed {
        await ledger.record(batch.count)
        return batch.count == 1 ? .callTool(batch[0]) : .callTools(batch)
      }
      offset += batch.count
    }
    return .complete("Synthetic scenario finished")
  }
  func observe(_ observation: ToolObservation, context: inout AgentContext) -> PlanRevision {
    let previous: Int
    if case .int(let count)? = context.workingMemory.value(for: "loop_fixture_count") {
      previous = count
    } else {
      previous = 0
    }
    context.workingMemory.set(.int(previous + 1), forKey: "loop_fixture_count")
    return .continue
  }
  func handleFailure(_ error: AgentError, context: inout AgentContext) throws -> PlanRevision {
    throw error
  }
}
private actor LoopFixtureTool: AgentTool {
  nonisolated let name: String
  nonisolated var description: String { "Synthetic loop verification only" }
  nonisolated var schema: ToolSchema {
    ToolSchema(
      parameters: [
        "query": ToolParameter(.string, description: "Synthetic query"),
        "page": ToolParameter(.integer, description: "Synthetic page"),
      ], required: ["query"])
  }
  nonisolated var permission: ToolPermission {
    name == "loop_write" ? .userConfirmation : .readOnly
  }
  nonisolated let isParallelSafe = true
  nonisolated let isCancellable = true
  var count = 0
  init(name: String) { self.name = name }
  func execute(arguments: ToolArguments) throws -> ToolResult {
    try Task.checkCancellation()
    count += 1
    return ToolResult(callID: "", toolName: name, text: "Synthetic result")
  }
}
private actor LoopFixtureGate: PermissionGate {
  var count = 0
  func decide(for call: ToolCall, tool: ToolDescriptor) -> PermissionDecision {
    count += 1
    return .approved
  }
}
private actor UnusedLoopModel: LocalModelProvider {
  var count = 0
  func generate(request: ModelRequest) throws -> ModelResponse {
    count += 1
    throw AgentError.modelUnavailable(reason: "Loop verifier must not generate")
  }
}
