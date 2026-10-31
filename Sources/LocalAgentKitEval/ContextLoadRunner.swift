import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime

/// Exercises SDK budgeting, not Phase 0's untrimmed final-prompt assembly. Tools are never run.
public enum ContextLoadRunner {
  public static func run(
    model: any LocalModelProvider, repetitions: Int = 1, limit: Int? = nil,
    profileID: String? = nil, probeID: String? = nil,
    toolModes: [ContextLoadResult.ToolMode] = ContextLoadResult.ToolMode.allCases,
    timeout: Duration = .seconds(60)
  ) async throws -> [ContextLoadResult] {
    guard (1...100).contains(repetitions), timeout > .zero,
      limit.map({ $0 > 0 }) ?? true, !toolModes.isEmpty,
      Set(toolModes.map(\.rawValue)).count == toolModes.count
    else { throw ProbeError.invalidOptions("Invalid context-load options.") }
    let fixture = try SuiteLoader.contextFixture()
    let profiles = fixture.profiles.filter { profileID == nil || $0.id == profileID }
    var probes = fixture.probes.filter { probeID == nil || $0.id == probeID }
    guard !profiles.isEmpty, !probes.isEmpty else {
      throw ProbeError.invalidOptions("Unknown context profile or probe.")
    }
    if let limit { probes = Array(probes.prefix(limit)) }
    let catalog = try SuiteLoader.tools().map(ProbeRunner.descriptor)
    var results: [ContextLoadResult] = []
    for profile in profiles {
      for mode in toolModes {
        for probe in probes {
          let inputs = try fixture.inputs(
            profile: profile, probe: probe, tools: mode == .registered ? catalog : [])
          for repetition in 1...repetitions {
            try Task.checkCancellation()
            let capture = ContextCapture()
            let observed = ContextObservedModel(base: model, capture: capture)
            let runtime = try AgentRuntime(
              configuration: AgentConfiguration(
                model: observed,
                limits: ExecutionLimits(
                  maxIterations: 1, maxToolCalls: 0,
                  maxDuration: timeout, maxModelCallDuration: timeout), networkPolicy: .never),
              tools: StaticToolSource([]),
              planner: ContextPlanner(inputs: inputs, capture: capture))
            let start = ContinuousClock.now
            var failure: AgentError?
            do { _ = try await runtime.run(probe.question) } catch is CancellationError {
              throw CancellationError()
            } catch let error as AgentError {
              if error == .cancelled { throw CancellationError() }
              failure = error
            }
            await runtime.finishEvents()
            let snapshot = await capture.snapshot()
            let duration = start.duration(to: .now).components
            results.append(
              makeResult(
                fixture: fixture, profile: profile, probe: probe, mode: mode,
                repetition: repetition, snapshot: snapshot, failure: failure,
                elapsed: Double(duration.seconds) + Double(duration.attoseconds) / 1e18))
          }
        }
      }
    }
    return results
  }

  static func sourceStatus(
    fixture: ContextLoadFixture, profile: ContextLoadFixture.Profile,
    probe: ContextLoadFixture.Probe, request: ModelRequest
  ) -> ContextLoadResult.SourceStatus {
    guard fixture.sourceIncluded(probe, profile: profile) else { return .absent }
    let text = request.messages.map(\.content).joined(separator: "\n")
    if fixture.sourceFragments(probe).contains(where: { text.contains($0) }) { return .retained }
    return probe.answerContainsAny.contains(where: { text.localizedCaseInsensitiveContains($0) })
      ? .uncertain : .removed
  }

  private static func makeResult(
    fixture: ContextLoadFixture, profile: ContextLoadFixture.Profile,
    probe: ContextLoadFixture.Probe, mode: ContextLoadResult.ToolMode, repetition: Int,
    snapshot: ContextSnapshot, failure: AgentError?, elapsed: Double
  ) -> ContextLoadResult {
    var outcome: ContextLoadResult.Outcome = .otherError
    var text: String?
    if let failure {
      switch failure {
      case .contextLimitExceeded:
        outcome = snapshot.delivered == nil ? .budgetExceeded : .modelExceeded
      case .executionTimeout: outcome = .timeout
      case .guardrailRefusal(let refusal):
        outcome = .refused
        text = refusal.explanation
      default: break
      }
    } else if let response = snapshot.response {
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
      case .toolCall, .multipleToolCalls: outcome = .unexpectedToolCall
      }
    }
    let after = snapshot.fitted.map {
      sourceStatus(fixture: fixture, profile: profile, probe: probe, request: $0.request)
    }
    let delivered = snapshot.delivered.map {
      sourceStatus(fixture: fixture, profile: profile, probe: probe, request: $0)
    }
    let matches =
      text.map { value in
        probe.answerContainsAny.contains { value.localizedCaseInsensitiveContains($0) }
      } ?? false
    var recall = "notScored"
    if outcome == .text, let delivered {
      switch delivered {
      case .retained: recall = matches ? "recalled" : "missed"
      case .uncertain: recall = "uncertain"
      case .absent, .removed: recall = matches ? "answerWithoutRetainedSource" : "needsReview"
      }
    }
    return ContextLoadResult(
      profileID: profile.id, probeID: probe.id, repetition: repetition, toolMode: mode,
      outcome: outcome, sourceIncludedBeforeFit: fixture.sourceIncluded(probe, profile: profile),
      sourceAfterFit: after, sourceAtGeneration: delivered, answerMatches: matches,
      recallAssessment: recall, response: text, error: failure.map { String(describing: $0) },
      beforeFit: snapshot.before, fittedTokens: snapshot.fitted?.utilization.usedTokens,
      fittedWindow: snapshot.fitted?.utilization.limitTokens,
      fittedTokensAreMeasured: snapshot.fittedMeasured, deliveredTokens: snapshot.tokens,
      generationStarted: snapshot.delivered != nil,
      trim: snapshot.fitted.map { ContextTrim($0.report) },
      elapsedSeconds: elapsed)
  }
}

private struct ContextSnapshot: Sendable {
  var before: ContextTokenMeasurements?
  var fitted: BudgetedContext?
  var fittedMeasured = false
  var delivered: ModelRequest?
  var tokens: Int?
  var response: ModelResponse?
}

private actor ContextCapture {
  var value = ContextSnapshot()
  func before(_ measurements: ContextTokenMeasurements) { value.before = measurements }
  func fitted(_ fitted: BudgetedContext, measured: Bool) {
    value.fitted = fitted
    value.fittedMeasured = measured
  }
  func delivered(_ request: ModelRequest, tokens: Int?) {
    value.delivered = request
    value.tokens = tokens
  }
  func response(_ response: ModelResponse) { value.response = response }
  func snapshot() -> ContextSnapshot { value }
}

private struct ContextObservedModel: LocalModelProvider {
  let base: any LocalModelProvider
  let capture: ContextCapture
  var requiresNetwork: Bool { base.requiresNetwork }
  var contextWindowTokens: Int? { base.contextWindowTokens }
  func tokenCount(for request: ModelRequest) async -> Int? { await base.tokenCount(for: request) }
  func generate(request: ModelRequest) async throws -> ModelResponse {
    let tokens = await base.tokenCount(for: request)
    await capture.delivered(request, tokens: tokens)
    return try await base.generate(request: request)
  }
}

private struct ContextPlanner: AgentPlanner {
  let inputs: ContextInputs
  let capture: ContextCapture
  func plan(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    async throws -> AgentPlan
  {
    let full = ContextBudgeter.untrimmedRequest(for: inputs)
    // Each prefix keeps the same final user question: the real provider cannot count a
    // system-only request. Question cost therefore belongs to the first component.
    let historyStart = full.messages.firstIndex { $0.role != .system } ?? full.messages.count
    let question = Array(full.messages.suffix(1))
    var ends = [("instructionsToolsAndQuestion", min(1, historyStart))]
    var systemEnd = 1
    if inputs.planState != nil {
      systemEnd += 1
      ends.append(("plan", systemEnd))
    }
    if !inputs.retrievedChunks.isEmpty {
      systemEnd += 1
      ends.append(("rag", systemEnd))
    }
    ends.append(("history", max(historyStart, full.messages.count - 1)))
    var prefixes: [String: Int] = [:]
    var components: [String: Int] = [:]
    var previous: Int? = 0
    for (name, end) in ends {
      let count = await model.tokenCount(
        for: ModelRequest(
          messages: Array(full.messages.prefix(end)) + question, tools: full.tools))
      prefixes[name] = count
      if let count, let previous { components[name] = count - previous }
      previous = count
    }
    await capture.before(
      ContextTokenMeasurements(
        total: prefixes["history"], prefixTokens: prefixes, componentTokens: components))
    let fitted = try await ContextBudgeter().fit(inputs, for: model)
    let measured = await model.tokenCount(for: fitted.request) != nil
    await capture.fitted(fitted, measured: measured)
    return AgentPlan(steps: [PlanStep(id: "context-probe", summary: "Read supplied material")])
  }
  func next(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    async throws -> PlannerDecision
  {
    guard let fitted = await capture.snapshot().fitted else {
      throw AgentError.contextLimitExceeded
    }
    // Runtime verifies the already-fitted request again before delivering it to the provider.
    await capture.response(try await model.generate(request: fitted.request))
    return .complete("Context probe captured; no tool executed.")
  }
  func observe(_ observation: ToolObservation, context: inout AgentContext) throws -> PlanRevision {
    .continue
  }
  func handleFailure(_ error: AgentError, context: inout AgentContext) throws -> PlanRevision {
    throw error
  }
}
