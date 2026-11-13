import Foundation

/// Encoded recorded audio already read and authorized by the host.
public struct AudioInput: Sendable, Hashable {
  /// Encoded audio bytes in a format accepted by the chosen recognizer.
  public let data: Data

  /// Creates an input without exposing native audio-framework objects.
  public init(data: Data) { self.data = data }
}

/// Recorded-audio transcription seam (FR-017).
public protocol SpeechRecognizer: Sendable {
  /// Whether transcription requires network access. Hosts must honor this declaration.
  var requiresNetwork: Bool { get }
  /// Returns final transcript text, or a typed AgentError.
  func transcribe(audio: AudioInput) async throws -> String
}

extension SpeechRecognizer {
  /// Defaults to local processing.
  public var requiresNetwork: Bool { false }
}
