import Foundation
import LocalAgentKitCore

/// Generates PCM WAV data through an available Apple system voice.
public struct AppleSpeechSynthesizer: SpeechSynthesizer {
  /// Uses an available local Apple voice.
  public let requiresNetwork = false
  /// Requested exact voice language when no identifier is supplied.
  public let localeIdentifier: String
  /// Explicit voice selection, or nil for deterministic selection by locale.
  public let voiceIdentifier: String?
  private let maximumCharacters: Int
  private let maximumAudioBytes: Int
  private let maximumDuration: Double
  private let timeout: Duration
  private let render:
    @Sendable (String, String, String?, Int, Double, Duration) async throws -> AudioOutput

  /// Defaults to en-US, 2,000 text characters, 16 MiB WAV output, 60 audio seconds
  /// and a 30-second generation timeout. Personal and third-party voices are excluded.
  public init(
    localeIdentifier: String = "en-US", voiceIdentifier: String? = nil,
    maximumCharacters: Int = 2000, maximumAudioBytes: Int = 16 * 1024 * 1024,
    maximumDuration: Double = 60, timeout: Duration = .seconds(30)
  ) throws {
    try self.init(
      localeIdentifier: localeIdentifier, voiceIdentifier: voiceIdentifier,
      maximumCharacters: maximumCharacters, maximumAudioBytes: maximumAudioBytes,
      maximumDuration: maximumDuration, timeout: timeout,
      render: { try await NativeSpeechOutput.render($0, $1, $2, $3, $4, $5) })
  }

  init(
    localeIdentifier: String = "en-US", voiceIdentifier: String? = nil,
    maximumCharacters: Int = 2000, maximumAudioBytes: Int = 16 * 1024 * 1024,
    maximumDuration: Double = 60, timeout: Duration = .seconds(30),
    render:
      @escaping @Sendable (String, String, String?, Int, Double, Duration) async throws ->
      AudioOutput
  ) throws {
    guard !localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      voiceIdentifier.map({ !$0.isEmpty }) ?? true, maximumCharacters > 0,
      maximumAudioBytes >= 46, maximumAudioBytes <= Int(UInt32.max),
      maximumDuration.isFinite, maximumDuration > 0, timeout > .zero
    else {
      throw AgentError.invalidConfiguration(.invalidLimit("Invalid speech synthesis configuration"))
    }
    self.localeIdentifier = localeIdentifier
    self.voiceIdentifier = voiceIdentifier
    self.maximumCharacters = maximumCharacters
    self.maximumAudioBytes = maximumAudioBytes
    self.maximumDuration = maximumDuration
    self.timeout = timeout
    self.render = render
  }

  /// Synthesizes nonblank bounded text, without playing the returned audio.
  public func synthesize(text: String) async throws -> AudioOutput {
    do {
      try Task.checkCancellation()
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        text.count <= maximumCharacters
      else { throw AgentError.speechFailure("Text is blank or exceeds the character limit") }
      let audio = try await render(
        text, localeIdentifier, voiceIdentifier, maximumAudioBytes, maximumDuration, timeout)
      try Task.checkCancellation()
      guard audio.data.count <= maximumAudioBytes, (1...192_000).contains(audio.sampleRate),
        (1...2).contains(audio.channelCount), audio.frameCount > 0,
        audio.data.count >= 44,
        (audio.data.count - 44) % (audio.channelCount * 2) == 0,
        (audio.data.count - 44) / (audio.channelCount * 2) == audio.frameCount,
        Double(audio.frameCount) / Double(audio.sampleRate) <= maximumDuration
      else {
        throw AgentError.speechFailure("Synthesized audio exceeds limits or has invalid metadata")
      }
      return audio
    } catch {
      if Task.isCancelled || error is CancellationError { throw AgentError.cancelled }
      if let error = error as? AgentError { throw error }
      throw AgentError.speechFailure("Speech synthesis failed")
    }
  }
}
