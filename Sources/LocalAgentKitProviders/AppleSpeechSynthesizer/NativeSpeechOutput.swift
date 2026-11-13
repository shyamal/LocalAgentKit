import AVFAudio
import Foundation
import LocalAgentKitCore

struct SpeechPCMChunk: Sendable {
  let data: Data
  let sampleRate: Int
  let channels: Int
  let frames: Int
}

@MainActor final class NativeSpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  nonisolated private let continuation: AsyncThrowingStream<SpeechPCMChunk, any Error>.Continuation

  private init(_ continuation: AsyncThrowingStream<SpeechPCMChunk, any Error>.Continuation) {
    self.continuation = continuation
    super.init()
    synthesizer.delegate = self
  }

  static func render(
    _ text: String, _ locale: String, _ identifier: String?, _ maximumBytes: Int,
    _ maximumDuration: Double, _ timeout: Duration
  ) async throws -> AudioOutput {
    try Task.checkCancellation()
    let voices = AVSpeechSynthesisVoice.speechVoices().filter {
      $0.identifier.hasPrefix("com.apple.") && !$0.voiceTraits.contains(.isPersonalVoice)
    }.sorted { $0.identifier < $1.identifier }
    guard
      let candidate = voices.first(where: {
        if let identifier { return $0.identifier == identifier }
        return $0.language.caseInsensitiveCompare(locale) == .orderedSame
      }), let voice = AVSpeechSynthesisVoice(identifier: candidate.identifier)
    else {
      throw AgentError.speechFailure("Requested local Apple voice is unavailable")
    }
    let channel = AsyncThrowingStream<SpeechPCMChunk, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(8))
    let session = NativeSpeechOutput(channel.continuation)
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    let deadline = Task {
      do { try await Task.sleep(for: timeout) } catch { return }
      session.continuation.finish(throwing: AgentError.speechFailure("Speech synthesis timed out"))
      session.synthesizer.stopSpeaking(at: .immediate)
    }
    defer {
      deadline.cancel()
      session.synthesizer.stopSpeaking(at: .immediate)
      channel.continuation.finish()
    }
    return try await withTaskCancellationHandler {
      session.synthesizer.write(utterance) { buffer in
        do {
          guard let buffer = buffer as? AVAudioPCMBuffer else {
            throw AgentError.speechFailure("Speech returned an unsupported audio buffer")
          }
          if buffer.frameLength == 0 {
            channel.continuation.finish()
            return
          }
          let chunk = try Self.copy(buffer, maximumBytes: maximumBytes)
          if case .dropped = channel.continuation.yield(chunk) {
            channel.continuation.finish(
              throwing: AgentError.speechFailure("Speech audio queue exceeded its limit"))
          }
        } catch { channel.continuation.finish(throwing: error) }
      }
      return try await collect(
        channel.stream, maximumBytes: maximumBytes, maximumDuration: maximumDuration)
    } onCancel: {
      channel.continuation.finish(throwing: AgentError.cancelled)
      Task { @MainActor in session.synthesizer.stopSpeaking(at: .immediate) }
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    continuation.finish(throwing: AgentError.speechFailure("Native speech synthesis was cancelled"))
  }

  nonisolated static func copy(_ buffer: AVAudioPCMBuffer, maximumBytes: Int) throws
    -> SpeechPCMChunk
  {
    let rate = buffer.format.sampleRate
    let channels = Int(buffer.format.channelCount)
    let frames = Int(buffer.frameLength)
    guard rate.isFinite, rate >= 1, rate <= 192_000, rate.rounded() == rate,
      (1...2).contains(channels), frames <= maximumBytes / (channels * 2)
    else { throw AgentError.speechFailure("Unsupported speech audio format or chunk size") }
    var data = Data()
    for frame in 0..<frames {
      for channel in 0..<channels {
        let offset = frame * buffer.stride
        let value: Float
        if let samples = buffer.floatChannelData {
          value = samples[channel][offset]
        } else if let samples = buffer.int16ChannelData {
          value = Float(samples[channel][offset]) / 32768
        } else if let samples = buffer.int32ChannelData {
          value = Float(samples[channel][offset]) / 2_147_483_648
        } else {
          throw AgentError.speechFailure("Unsupported speech audio sample type")
        }
        guard value.isFinite else { throw AgentError.speechFailure("Invalid speech audio samples") }
        let clamped = max(-1, min(1, value))
        let sample = Int16(clamped < 0 ? clamped * 32768 : clamped * 32767)
        let bits = UInt16(bitPattern: sample)
        data.append(UInt8(truncatingIfNeeded: bits))
        data.append(UInt8(truncatingIfNeeded: bits >> 8))
      }
    }
    return SpeechPCMChunk(data: data, sampleRate: Int(rate), channels: channels, frames: frames)
  }

  nonisolated static func collect(
    _ stream: AsyncThrowingStream<SpeechPCMChunk, any Error>,
    maximumBytes: Int, maximumDuration: Double
  ) async throws -> AudioOutput {
    var pcm = Data()
    var rate = 0
    var channels = 0
    var frames = 0
    for try await chunk in stream {
      try Task.checkCancellation()
      if rate == 0 {
        rate = chunk.sampleRate
        channels = chunk.channels
      }
      guard (1...192_000).contains(rate), (1...2).contains(channels),
        chunk.sampleRate == rate, chunk.channels == channels,
        chunk.data.count % (channels * 2) == 0,
        chunk.data.count / (channels * 2) == chunk.frames,
        chunk.data.count <= maximumBytes - 44 - pcm.count,
        chunk.frames > 0, chunk.frames <= maximumBytes,
        Double(frames + chunk.frames) / Double(rate) <= maximumDuration
      else {
        throw AgentError.speechFailure("Speech audio exceeds output limits or changed format")
      }
      pcm.append(chunk.data)
      frames += chunk.frames
    }
    try Task.checkCancellation()
    guard frames > 0 else { throw AgentError.speechFailure("Speech produced no audio") }
    var wav = Data()
    func word(_ value: UInt32, bytes: Int) {
      for index in 0..<bytes { wav.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
    }
    wav.append(contentsOf: "RIFF".utf8)
    word(UInt32(36 + pcm.count), bytes: 4)
    wav.append(contentsOf: "WAVEfmt ".utf8)
    word(16, bytes: 4)
    word(1, bytes: 2)
    word(UInt32(channels), bytes: 2)
    word(UInt32(rate), bytes: 4)
    word(UInt32(rate * channels * 2), bytes: 4)
    word(UInt32(channels * 2), bytes: 2)
    word(16, bytes: 2)
    wav.append(contentsOf: "data".utf8)
    word(UInt32(pcm.count), bytes: 4)
    wav.append(pcm)
    return AudioOutput(data: wav, sampleRate: rate, channelCount: channels, frameCount: frames)
  }
}
