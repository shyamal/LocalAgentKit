import AVFAudio
import Foundation
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitProviders

@Suite struct AppleSpeechSynthesizerTests {
  static let pcm = Data([0, 0, 255, 127, 0, 128])
  static func audio() async throws -> AudioOutput {
    let stream = AsyncThrowingStream<SpeechPCMChunk, any Error> { continuation in
      continuation.yield(.init(data: pcm, sampleRate: 16_000, channels: 1, frames: 3))
      continuation.finish()
    }
    return try await NativeSpeechOutput.collect(stream, maximumBytes: 100, maximumDuration: 1)
  }

  @Test func publicEntryPreservesConfigurationAndEncodedAudio() async throws {
    let audio = try await Self.audio()
    let provider = try AppleSpeechSynthesizer(
      localeIdentifier: "en-US", voiceIdentifier: "com.apple.example", maximumCharacters: 2,
      maximumAudioBytes: 50, maximumDuration: 1, timeout: .seconds(2)
    ) { text, locale, voice, bytes, duration, timeout in
      #expect(text == "é👩🏽‍💻" && locale == "en-US" && voice == "com.apple.example")
      #expect(bytes == 50 && duration == 1 && timeout == .seconds(2))
      return audio
    }
    #expect(!provider.requiresNetwork)
    #expect(try await provider.synthesize(text: "é👩🏽‍💻") == audio)
    #expect(audio.data.prefix(4) == Data("RIFF".utf8))
    #expect(audio.data.suffix(6) == Self.pcm)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try audio.data.write(to: url)
    let file = try AVAudioFile(forReading: url)
    #expect(file.length == 3 && file.processingFormat.sampleRate == 16_000)
  }

  @Test func invalidTextAndSettingsDoNotRender() async throws {
    let provider = try AppleSpeechSynthesizer(maximumCharacters: 2) { _, _, _, _, _, _ in
      Issue.record("Invalid input reached rendering")
      return try await Self.audio()
    }
    for text in ["", "   ", "long"] {
      await #expect(
        throws: AgentError.speechFailure("Text is blank or exceeds the character limit")
      ) {
        try await provider.synthesize(text: text)
      }
    }
    for settings in [
      ("", 1, 46, 1.0), ("en-US", 0, 46, 1.0), ("en-US", 1, 45, 1.0), ("en-US", 1, 46, Double.nan),
    ] {
      #expect(throws: AgentError.self) {
        try AppleSpeechSynthesizer(
          localeIdentifier: settings.0, maximumCharacters: settings.1,
          maximumAudioBytes: settings.2, maximumDuration: settings.3)
      }
    }
    #expect(throws: AgentError.self) { try AppleSpeechSynthesizer(timeout: .zero) }
    #expect(throws: AgentError.self) { try AppleSpeechSynthesizer(voiceIdentifier: "") }
  }

  @Test func chunkCollectorRejectsChangedFormatsMalformedChunksAndLimits() async throws {
    let valid = SpeechPCMChunk(data: Self.pcm, sampleRate: 16_000, channels: 1, frames: 3)
    for chunk in [
      SpeechPCMChunk(data: Self.pcm, sampleRate: 0, channels: 1, frames: 3),
      .init(data: Self.pcm, sampleRate: 16_000, channels: 0, frames: 3),
      .init(data: Self.pcm, sampleRate: 16_000, channels: 1, frames: 4),
      .init(data: Self.pcm, sampleRate: 8_000, channels: 1, frames: 3),
    ] {
      let stream = AsyncThrowingStream<SpeechPCMChunk, any Error> {
        $0.yield(valid)
        $0.yield(chunk)
        $0.finish()
      }
      await #expect(throws: AgentError.self) {
        try await NativeSpeechOutput.collect(stream, maximumBytes: 100, maximumDuration: 1)
      }
    }
    for (bytes, seconds) in [(49, 1.0), (100, 0.0001)] {
      let stream = AsyncThrowingStream<SpeechPCMChunk, any Error> {
        $0.yield(valid)
        $0.finish()
      }
      await #expect(throws: AgentError.self) {
        try await NativeSpeechOutput.collect(stream, maximumBytes: bytes, maximumDuration: seconds)
      }
    }
    let empty = AsyncThrowingStream<SpeechPCMChunk, any Error> { $0.finish() }
    await #expect(throws: AgentError.speechFailure("Speech produced no audio")) {
      try await NativeSpeechOutput.collect(empty, maximumBytes: 100, maximumDuration: 1)
    }
  }

  @Test func nativeBufferCopiesPCMWithCorrectClampingAndChannelOrder() throws {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
    buffer.frameLength = 2
    let samples = try #require(buffer.floatChannelData)
    samples[0][0] = 2
    samples[1][0] = -2
    samples[0][1] = 0
    samples[1][1] = 0
    let chunk = try NativeSpeechOutput.copy(buffer, maximumBytes: 100)
    #expect(chunk.data == Data([255, 127, 0, 128, 0, 0, 0, 0]))
    samples[0][0] = .nan
    #expect(throws: AgentError.speechFailure("Invalid speech audio samples")) {
      try NativeSpeechOutput.copy(buffer, maximumBytes: 100)
    }
  }

  @Test func integerBuffersAndCancelledCollectionAreHandled() async throws {
    for type in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatInt32] {
      let format = try #require(
        AVAudioFormat(
          commonFormat: type, sampleRate: 16_000, channels: 1, interleaved: false))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
      buffer.frameLength = 1
      if let samples = buffer.int16ChannelData { samples[0][0] = .min }
      if let samples = buffer.int32ChannelData { samples[0][0] = .min }
      #expect(try NativeSpeechOutput.copy(buffer, maximumBytes: 100).data == Data([0, 128]))
    }
    await #expect(throws: CancellationError.self) {
      try await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        let stream = AsyncThrowingStream<SpeechPCMChunk, any Error> { $0.finish() }
        return try await NativeSpeechOutput.collect(stream, maximumBytes: 100, maximumDuration: 1)
      }.value
    }
  }

  @Test func errorsAndCancellationRemainTyped() async throws {
    for mode in 0..<4 {
      let provider = try AppleSpeechSynthesizer { _, _, _, _, _, _ in
        switch mode {
        case 0: throw CocoaError(.fileReadCorruptFile)
        case 1: throw AgentError.speechFailure("scripted")
        case 2: throw CancellationError()
        default:
          withUnsafeCurrentTask { $0?.cancel() }
          return try await Self.audio()
        }
      }
      let expected: AgentError =
        mode >= 2 ? .cancelled : .speechFailure(mode == 0 ? "Speech synthesis failed" : "scripted")
      await #expect(throws: expected) {
        try await Task { try await provider.synthesize(text: "hello") }.value
      }
    }
  }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALAGENTKIT_DEVICE_TESTS"] == "1"))
struct AppleSpeechSynthesisNativeTests {
  @Test func availableAppleVoiceProducesDecodableWAV() async throws {
    let voice = AVSpeechSynthesisVoice.speechVoices().first {
      $0.identifier.hasPrefix("com.apple.") && !$0.voiceTraits.contains(.isPersonalVoice)
        && $0.language == "en-US"
    }
    guard let voice else {
      print("Speech synthesis native check: no en-US Apple voice available")
      let provider = try AppleSpeechSynthesizer()
      await #expect(throws: AgentError.speechFailure("Requested local Apple voice is unavailable"))
      {
        try await provider.synthesize(text: "Hello")
      }
      return
    }
    let provider = try AppleSpeechSynthesizer(
      voiceIdentifier: voice.identifier, timeout: .seconds(10))
    let output = try await provider.synthesize(text: "Hello from Local Agent Kit.")
    #expect(output.frameCount > 0)
    #expect(output.data.dropFirst(44).contains { $0 != 0 })
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try output.data.write(to: url)
    let decoded = try AVAudioFile(forReading: url)
    #expect(decoded.length == output.frameCount)
    #expect(decoded.processingFormat.sampleRate == Double(output.sampleRate))
    print("Speech synthesis native check: produced and decoded WAV audio")
  }

  @Test func generationTimeoutStopsARequest() async throws {
    let provider = try AppleSpeechSynthesizer(timeout: .milliseconds(1))
    let available = AVSpeechSynthesisVoice.speechVoices().contains {
      $0.identifier.hasPrefix("com.apple.") && !$0.voiceTraits.contains(.isPersonalVoice)
        && $0.language == "en-US"
    }
    guard available else { return }
    await #expect(throws: AgentError.speechFailure("Speech synthesis timed out")) {
      try await provider.synthesize(
        text: String(repeating: "Hello from the local speech test. ", count: 40))
    }
  }

  @Test func unknownVoiceFailsExplicitly() async throws {
    let provider = try AppleSpeechSynthesizer(voiceIdentifier: "com.apple.nonexistent.voice")
    await #expect(throws: AgentError.speechFailure("Requested local Apple voice is unavailable")) {
      try await provider.synthesize(text: "Hello")
    }
  }
}
