import Foundation
import LocalAgentKitCore
import Speech
import Testing

@testable import LocalAgentKitProviders

@Suite struct AppleSpeechRecognizerTests {
  actor Recording {
    var url: URL?
    func save(_ value: URL) { url = value }
  }

  @Test func decodesRealAudioAndRemovesItsPrivateTemporaryFile() async throws {
    let recording = Recording()
    let audio = AudioInput(data: Self.silence())
    let provider = try AppleSpeechRecognizer(maximumBytes: audio.data.count, maximumDuration: 1) {
      url, locale, limit in
      await recording.save(url)
      #expect(locale == "en-US" && limit == 20_000)
      #expect(try Data(contentsOf: url) == audio.data)
      let mode =
        try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[
          .posixPermissions] as? NSNumber
      #expect(mode?.intValue == 0o700)
      return "Recorded speech"
    }
    #expect(!provider.requiresNetwork)
    #expect(try await provider.transcribe(audio: audio) == "Recorded speech")
    let url = try #require(await recording.url)
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
  }

  @Test func invalidBytesAndDecodedDurationNeverReachRecognition() async throws {
    let audio = Self.silence()
    for (data, bytes, duration) in [
      (Data(), 100, 1.0), (Data([1, 2, 3]), 100, 1.0),
      (audio, audio.count - 1, 1.0), (audio, audio.count, 0.99),
    ] {
      let provider = try AppleSpeechRecognizer(maximumBytes: bytes, maximumDuration: duration) {
        _, _, _ in
        Issue.record("Invalid audio reached recognition")
        return ""
      }
      await #expect(throws: AgentError.self) {
        try await provider.transcribe(audio: AudioInput(data: data))
      }
    }
  }

  @Test func invalidConfigurationFailsAtConstruction() {
    for settings in [
      ("", 1, 1.0, 1), ("en-US", 0, 1.0, 1), ("en-US", 1, Double.nan, 1), ("en-US", 1, -1.0, 1),
      ("en-US", 1, 1.0, 0),
    ] {
      #expect(throws: AgentError.self) {
        try AppleSpeechRecognizer(
          localeIdentifier: settings.0, maximumBytes: settings.1,
          maximumDuration: settings.2, maximumCharacters: settings.3)
      }
    }
  }

  @Test func outputLimitCountsSwiftCharactersAndAcceptsEmptyRecognition() async throws {
    let audio = AudioInput(data: Self.silence())
    for text in ["", "é👩🏽‍💻", "too long"] {
      let provider = try AppleSpeechRecognizer(maximumCharacters: 2) { _, _, _ in text }
      if text.count <= 2 {
        #expect(try await provider.transcribe(audio: audio) == text)
      } else {
        await #expect(throws: AgentError.speechFailure("Transcript exceeds the character limit")) {
          try await provider.transcribe(audio: audio)
        }
      }
    }
  }

  @Test func errorsAndCancellationCleanUpWithoutReturningPartialText() async throws {
    let audio = AudioInput(data: Self.silence())
    for mode in 0..<4 {
      let recording = Recording()
      let provider = try AppleSpeechRecognizer { url, _, _ in
        await recording.save(url)
        switch mode {
        case 0: throw CocoaError(.fileReadCorruptFile)
        case 1: throw AgentError.speechFailure("scripted")
        case 2: throw CancellationError()
        default:
          withUnsafeCurrentTask { $0?.cancel() }
          return "Late"
        }
      }
      let expected: AgentError =
        mode >= 2
        ? .cancelled
        : .speechFailure(mode == 0 ? "Recorded audio transcription failed" : "scripted")
      await #expect(throws: expected) {
        try await Task { try await provider.transcribe(audio: audio) }.value
      }
      let url = try #require(await recording.url)
      #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }
    let cancelled = try AppleSpeechRecognizer { _, _, _ in
      Issue.record("Cancelled input reached recognition")
      return ""
    }
    await #expect(throws: AgentError.cancelled) {
      try await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await cancelled.transcribe(audio: audio)
      }.value
    }
  }

  actor Latch {
    private var open = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async {
      if !open { await withCheckedContinuation { waiting = $0 } }
    }
    func release() {
      open = true
      waiting?.resume()
      waiting = nil
    }
  }

  @Test func sessionReturnsTextOnlyAfterFeedingAndReadingFinish() async throws {
    let value = try await AppleSpeechRecognizer.runSession(
      start: {}, read: { "Final text" },
      cancel: { Issue.record("Successful session was cancelled") })
    #expect(value == "Final text")
  }

  @Test func eitherSessionFailureCancelsAndReleasesTheOtherSide() async {
    for failStart in [true, false] {
      let latch = Latch()
      await #expect(throws: AgentError.speechFailure("session failure")) {
        try await AppleSpeechRecognizer.runSession(
          start: {
            if failStart { throw AgentError.speechFailure("session failure") }
            await latch.wait()
          },
          read: {
            if !failStart { throw AgentError.speechFailure("session failure") }
            await latch.wait()
            return "Late"
          },
          cancel: { await latch.release() })
      }
    }
  }

  @Test func externalCancellationReleasesAnActiveSession() async {
    let ready = Latch()
    let released = Latch()
    let task = Task {
      try await AppleSpeechRecognizer.runSession(
        start: { await ready.release() },
        read: {
          await released.wait()
          try Task.checkCancellation()
          return "Late"
        },
        cancel: { await released.release() })
    }
    await ready.wait()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  static func silence() -> Data {
    let frames: UInt32 = 16_000
    let bytes = frames * 2
    var data = Data()
    func word(_ value: UInt32, bytes: Int) {
      for shift in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }
    data.append(contentsOf: "RIFF".utf8)
    word(36 + bytes, bytes: 4)
    data.append(contentsOf: "WAVEfmt ".utf8)
    word(16, bytes: 4)
    word(1, bytes: 2)
    word(1, bytes: 2)
    word(frames, bytes: 4)
    word(frames * 2, bytes: 4)
    word(2, bytes: 2)
    word(16, bytes: 2)
    data.append(contentsOf: "data".utf8)
    word(bytes, bytes: 4)
    data.append(Data(repeating: 0, count: Int(bytes)))
    return data
  }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALAGENTKIT_DEVICE_TESTS"] == "1"))
struct AppleSpeechNativeTests {
  @Test func nativePathHonorsInstalledAssetState() async throws {
    let audio = AudioInput(data: AppleSpeechRecognizerTests.silence())
    let provider = try AppleSpeechRecognizer()
    guard SpeechTranscriber.isAvailable,
      let locale = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: "en-US"))
    else {
      print("Speech native check: hardware or en-US unsupported")
      await #expect(
        throws: AgentError.speechFailure(
          "Speech recognition is unavailable for the requested locale")
      ) {
        try await provider.transcribe(audio: audio)
      }
      return
    }
    let module = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    let installed = await AssetInventory.status(forModules: [module]) == .installed
    if installed {
      print("Speech native check: installed en-US assets, testing silence")
      #expect(try await provider.transcribe(audio: audio).isEmpty)
    } else {
      print("Speech native check: en-US assets absent; no installation requested")
      await #expect(
        throws: AgentError.speechFailure(
          "Speech recognition assets are not installed for the requested locale")
      ) {
        try await provider.transcribe(audio: audio)
      }
    }
  }

  @Test func unsupportedLocaleFailsWithoutAssetProvisioning() async throws {
    let provider = try AppleSpeechRecognizer(localeIdentifier: "zz-ZZ")
    await #expect(
      throws: AgentError.speechFailure("Speech recognition is unavailable for the requested locale")
    ) {
      try await provider.transcribe(audio: AudioInput(data: AppleSpeechRecognizerTests.silence()))
    }
  }
}
