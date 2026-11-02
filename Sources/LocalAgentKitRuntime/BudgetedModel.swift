import Foundation
import LocalAgentKitCore

/// The model as the planner sees it: the provider wrapped so that **every** call is budgeted,
/// bounded, and observable, whoever makes it.
///
/// Context is fitted before the call, not after it fails (R2). The call gets a deadline: the
/// per-call limit, capped by what is left of the run. It is abandoned if it ignores cancellation.
struct BudgetedModel: LocalModelProvider {
  let base: any LocalModelProvider
  let budgeter: ContextBudgeter
  let limits: ExecutionLimits
  let clock: RunClock
  let events: EventBus
  /// Retrieved once per run (M1-RG-05), before the loop starts, and given to every call this
  /// model makes — RAG passages get the budgeter's own `retrievalShare` rather than competing
  /// with conversation history for the same tokens.
  var retrievedChunks: [String] = []
  var trace: RuntimeTrace? = nil
  var thermal: ThermalController? = nil

  var requiresNetwork: Bool { base.requiresNetwork }
  var contextWindowTokens: Int? { base.contextWindowTokens }

  func tokenCount(for request: ModelRequest) async -> Int? {
    await base.tokenCount(for: request)
  }

  func generate(request: ModelRequest) async throws -> ModelResponse {
    let interval = trace?.begin(.modelCall)
    defer { interval?.end() }
    var effectiveLimits = limits
    if let status = try await thermal?.checkpoint(), let cap = status.contextTokenCap {
      effectiveLimits.maxContextTokens = min(limits.maxContextTokens ?? cap, cap)
    }
    let remaining = await clock.remaining()
    guard remaining > .zero else { throw AgentError.executionTimeout(.run) }
    let perCall = limits.maxModelCallDuration
    let (allowed, scope) =
      perCall <= remaining ? (perCall, TimeoutScope.modelCall) : (remaining, .run)

    var inputs = Self.inputs(from: request)
    inputs.retrievedChunks = retrievedChunks
    var fitted = try await budgeter.fit(inputs, for: base, limits: effectiveLimits, events: events)
    // Token counting can itself take time. Recheck immediately before generation and refit
    // only on a stricter cap; two elevated caps bound the number of extra fits.
    while let status = try await thermal?.checkpoint(), let cap = status.contextTokenCap,
      cap < (effectiveLimits.maxContextTokens ?? Int.max)
    {
      effectiveLimits.maxContextTokens = cap
      fitted = try await budgeter.fit(inputs, for: base, limits: effectiveLimits, events: events)
    }
    await events.publish(.thinking)

    let model = base
    var fittedRequest = fitted.request
    fittedRequest.purpose = request.purpose
    let finalRequest = fittedRequest
    let channel: UUID?
    if request.purpose == .answer, request.tools.isEmpty {
      channel = await events.openResponseChannel()
    } else {
      channel = nil
    }
    do {
      let response = try await withDeadline(allowed, scope: scope) {
        if let channel {
          return try await model.generate(request: finalRequest) { token in
            guard !Task.isCancelled else { return }
            await events.publishResponseToken(token, channel: channel)
          }
        }
        return try await model.generate(request: finalRequest)
      }
      if let channel { await events.closeResponseChannel(channel) }
      return response
    } catch {
      if let channel { await events.closeResponseChannel(channel) }
      if let error = error as? AgentError { throw error }
      if error is CancellationError { throw AgentError.cancelled }
      throw AgentError.modelUnavailable(reason: String(describing: error))
    }
  }

  /// Leading system messages are the instructions; the rest is the conversation. The tools a
  /// request carries are never dropped: they are what the call is asking about.
  static func inputs(from request: ModelRequest) -> ContextInputs {
    let leading = request.messages.prefix { $0.role == .system }
    return ContextInputs(
      instructions: leading.map(\.content).joined(separator: "\n\n"),
      tools: request.tools,
      requiredToolNames: Set(request.tools.map(\.name)),
      conversation: Array(request.messages.dropFirst(leading.count)))
  }
}
