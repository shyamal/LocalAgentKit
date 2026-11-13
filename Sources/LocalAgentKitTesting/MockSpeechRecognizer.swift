import LocalAgentKitCore

/// Scripted recorded-audio recognizer that does not load native assets.
public actor MockSpeechRecognizer: SpeechRecognizer {
  /// Explicit network declaration for host-policy tests.
  public nonisolated let requiresNetwork: Bool
  private let handler: @Sendable (AudioInput) async throws -> String
  private var recorded: [AudioInput] = []

  /// Creates a recognizer returning an empty transcript by default.
  public init(
    requiresNetwork: Bool = false,
    handler: @escaping @Sendable (AudioInput) async throws -> String = { _ in "" }
  ) {
    self.requiresNetwork = requiresNetwork
    self.handler = handler
  }

  /// Inputs received by calls that were not already cancelled.
  public var inputs: [AudioInput] { recorded }

  /// Records the audio and checks cancellation before and after the handler.
  public func transcribe(audio: AudioInput) async throws -> String {
    do {
      try Task.checkCancellation()
      recorded.append(audio)
      let text = try await handler(audio)
      try Task.checkCancellation()
      return text
    } catch {
      if Task.isCancelled || error is CancellationError { throw AgentError.cancelled }
      if let error = error as? AgentError { throw error }
      throw AgentError.speechFailure("Mock speech recognition failed")
    }
  }
}
