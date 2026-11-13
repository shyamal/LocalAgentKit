import Foundation

/// Encoded signed 16-bit little-endian PCM WAV audio with its stream metadata.
public struct AudioOutput: Sendable, Hashable {
  /// Complete WAV file bytes.
  public let data: Data
  /// Sample frames per second.
  public let sampleRate: Int
  /// Number of interleaved channels.
  public let channelCount: Int
  /// Number of sample frames per channel.
  public let frameCount: Int

  /// Creates an encoded audio value.
  public init(data: Data, sampleRate: Int, channelCount: Int, frameCount: Int) {
    self.data = data
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.frameCount = frameCount
  }
}

/// Text-to-audio seam (FR-017). Playback is owned by the host.
public protocol SpeechSynthesizer: Sendable {
  /// Whether generating audio requires network access.
  var requiresNetwork: Bool { get }
  /// Returns encoded audio or a typed AgentError.
  func synthesize(text: String) async throws -> AudioOutput
}

extension SpeechSynthesizer {
  /// Defaults to local processing.
  public var requiresNetwork: Bool { false }
}
