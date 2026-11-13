import LocalAgentKitCore

/// Records synthesis requests and returns scripted audio without speaking or loading voices.
public actor MockSpeechSynthesizer: SpeechSynthesizer {
  /// Explicit network declaration for host-policy tests.
  public nonisolated let requiresNetwork: Bool
  private let handler: @Sendable (String) async throws -> AudioOutput
  private var recorded: [String] = []

  /// Creates a mock with a host-supplied audio result.
  public init(
    requiresNetwork: Bool = false,
    handler: @escaping @Sendable (String) async throws -> AudioOutput
  ) {
    self.requiresNetwork = requiresNetwork
    self.handler = handler
  }

  /// Text received by calls that were not already cancelled.
  public var inputs: [String] { recorded }

  /// Records text and checks cancellation before and after generating its result.
  public func synthesize(text: String) async throws -> AudioOutput {
    do {
      try Task.checkCancellation()
      recorded.append(text)
      let audio = try await handler(text)
      try Task.checkCancellation()
      return audio
    } catch {
      if Task.isCancelled || error is CancellationError { throw AgentError.cancelled }
      if let error = error as? AgentError { throw error }
      throw AgentError.speechFailure("Mock speech synthesis failed")
    }
  }
}
