import LocalAgentKitCore

/// A model whose behavior is a closure, for tests that care about what the model is *asked*
/// rather than about a fixed sequence of answers. Records every request.
public actor MockModelProvider: LocalModelProvider {
  /// Asynchronous response factory receiving each recorded model request.
  public typealias Handler = @Sendable (ModelRequest) async throws -> ModelResponse

  /// Configurable network declaration used to test offline-policy rejection.
  public nonisolated let requiresNetwork: Bool
  /// Optional window advertised to context-budget tests.
  public nonisolated let contextWindowTokens: Int?
  private let handler: Handler
  private let tokenCounter: (@Sendable (ModelRequest) -> Int?)?
  private var recorded: [ModelRequest] = []

  /// - Parameter requiresNetwork: Whether this test provider declares network use.
  /// - Parameter contextWindowTokens: The test model context window, if known.
  /// - Parameter handler: Computes a scripted response from each recorded request.
  /// - Parameter tokenCounter: Stands in for the platform's token counter. Nil means the
  ///   provider cannot count, as on an OS without `tokenCount(for:)`.
  public init(
    requiresNetwork: Bool = false,
    contextWindowTokens: Int? = nil,
    handler: @escaping Handler = { _ in .text("mock") },
    tokenCounter: (@Sendable (ModelRequest) -> Int?)? = nil
  ) {
    self.requiresNetwork = requiresNetwork
    self.contextWindowTokens = contextWindowTokens
    self.tokenCounter = tokenCounter
    self.handler = handler
  }

  /// Invokes the configured token counter, or returns nil when none is supplied.
  public func tokenCount(for request: ModelRequest) async -> Int? {
    tokenCounter?(request)
  }

  /// Every request received, oldest first.
  public var requests: [ModelRequest] { recorded }

  /// Records the request, checks cancellation and invokes the response handler.
  public func generate(request: ModelRequest) async throws -> ModelResponse {
    recorded.append(request)
    do {
      try Task.checkCancellation()
      return try await handler(request)
    } catch is CancellationError {
      throw AgentError.cancelled
    }
  }
}

/// A model that plays back a fixed script, one step per call, for deterministic loop tests.
/// Running past the end of the script is a loud failure, so a loop that makes an unexpected extra
/// call cannot pass by accident.
public actor ScriptedModelProvider: LocalModelProvider {
  /// One response, failure or delay consumed by a scripted model call.
  public enum Step: Sendable {
    /// Delivers ordered text fragments to a streaming caller, then returns the supplied response.
    /// Ordinary generation returns only the response, keeping internal decisions private.
    case stream([String], then: ModelResponse)
    /// Delivers fragments to a streaming caller, then fails with a typed error.
    case streamFailure([String], error: AgentError)
    /// Return this model response immediately after the entry cancellation check.
    case respond(ModelResponse)
    /// Throw this typed error immediately after the entry cancellation check.
    case fail(AgentError)
    /// Waits, then answers. Uses the suspending clock, so a test can pair it with a short limit.
    case delay(Duration, then: ModelResponse)
    /// Never answers; ends only when the task is cancelled. For per-call deadline and
    /// cancellation tests.
    case hang
  }

  /// Configurable network requirement used by policy tests.
  public nonisolated let requiresNetwork: Bool
  /// Optional context window used by budgeting tests.
  public nonisolated let contextWindowTokens: Int?
  private var script: [Step]
  private var recorded: [ModelRequest] = []

  /// Creates a consumable script with configurable network and context-window declarations.
  public init(
    _ script: [Step], requiresNetwork: Bool = false, contextWindowTokens: Int? = nil
  ) {
    self.script = script
    self.requiresNetwork = requiresNetwork
    self.contextWindowTokens = contextWindowTokens
  }

  /// Creates a script of immediate responses with local-network defaults.
  public init(responses: [ModelResponse]) {
    self.init(responses.map(Step.respond))
  }

  /// Requests received in generation order, including the one that exhausts the script.
  public var requests: [ModelRequest] { recorded }
  /// Steps not yet played. A test that expects the loop to consume the whole script asserts zero.
  public var remainingSteps: Int { script.count }

  /// Records a request and consumes one step; an exhausted script throws modelUnavailable.
  /// Cancellation is normalized to AgentError.cancelled.
  public func generate(request: ModelRequest) async throws -> ModelResponse {
    try await consume(request: request, onToken: nil)
  }

  /// Consumes the next step and delivers its fragments only for an explicitly streaming call.
  public func generate(
    request: ModelRequest, onToken: @escaping @Sendable (String) async -> Void
  ) async throws -> ModelResponse {
    try await consume(request: request, onToken: onToken)
  }

  private func consume(
    request: ModelRequest, onToken: (@Sendable (String) async -> Void)?
  ) async throws -> ModelResponse {
    recorded.append(request)
    guard !script.isEmpty else {
      throw AgentError.modelUnavailable(reason: "ScriptedModelProvider: script exhausted")
    }
    let step = script.removeFirst()
    do {
      try Task.checkCancellation()
      switch step {
      case .stream(let tokens, let response):
        for token in tokens {
          try Task.checkCancellation()
          await onToken?(token)
        }
        try Task.checkCancellation()
        return response
      case .streamFailure(let tokens, let error):
        for token in tokens {
          try Task.checkCancellation()
          await onToken?(token)
        }
        try Task.checkCancellation()
        throw error
      case .respond(let response):
        return response
      case .fail(let error):
        throw error
      case .delay(let duration, let response):
        try await Task.sleep(for: duration)
        return response
      case .hang:
        while true { try await Task.sleep(for: .seconds(3600)) }
      }
    } catch is CancellationError {
      throw AgentError.cancelled
    }
  }
}
