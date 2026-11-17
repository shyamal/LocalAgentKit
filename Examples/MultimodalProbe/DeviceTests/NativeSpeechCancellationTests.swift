import Foundation
import LocalAgentKitCore
import Speech
import Synchronization
import XCTest

@testable import LocalAgentKitProviders

/// No recordings, transcript text, or installation requests leave this test.
private final class CancellationProbe: Sendable {
  struct State {
    var task: Task<String, any Error>?
    var progressed = false
    var recording: URL?
    var existedAtProgress = false
    var cancellationTime: ContinuousClock.Instant?
  }
  let state = Mutex(State())

  func progress() {
    state.withLock { value in
      guard !value.progressed else { return }
      value.progressed = true
      value.existedAtProgress =
        value.recording.map {
          FileManager.default.fileExists(atPath: $0.path)
        } ?? false
      value.cancellationTime = .now
      value.task?.cancel()
    }
  }

  func arm(_ task: Task<String, any Error>) {
    state.withLock { value in
      value.task = task
      if value.progressed { task.cancel() }
    }
  }
}

@MainActor final class NativeSpeechCancellationTests: XCTestCase {
  func testActiveNativeCancellationCleansUpAndAllowsAnotherTranscription() async throws {
    guard SpeechTranscriber.isAvailable,
      let locale = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: "en-US"))
    else { throw XCTSkip("Native English transcription is unsupported") }
    let module = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    guard await AssetInventory.status(forModules: [module]) == .installed else {
      throw XCTSkip("Prepare English speech data in the host before native acceptance")
    }
    let synthesizer = try AppleSpeechSynthesizer(timeout: .seconds(30))
    let phrase = "This is a synthetic local speech cancellation test. "
    let recording = try await synthesizer.synthesize(text: String(repeating: phrase, count: 5))
    let probe = CancellationProbe()
    let recognizer = try AppleSpeechRecognizer { url, locale, limit in
      probe.state.withLock { $0.recording = url }
      return try await AppleSpeechRecognizer.recognize(
        url, localeIdentifier: locale, maximumCharacters: limit,
        onAnalysisProgress: { probe.progress() })
    }
    let task = Task { try await recognizer.transcribe(audio: AudioInput(data: recording.data)) }
    probe.arm(task)
    // A watchdog prevents a missing native progress callback from hanging acceptance.
    // It cannot satisfy the assertion that progress caused cancellation.
    let watchdog = Task {
      try await Task.sleep(for: .seconds(30))
      task.cancel()
    }
    defer {
      watchdog.cancel()
      probe.state.withLock { $0.task = nil }
    }
    do {
      _ = try await task.value
      XCTFail("Native transcription completed instead of observing cancellation")
    } catch {
      XCTAssertEqual(error as? AgentError, .cancelled)
    }
    let observed = probe.state.withLock {
      ($0.progressed, $0.existedAtProgress, $0.recording, $0.cancellationTime)
    }
    XCTAssertTrue(observed.0, "Cancellation must follow a nonempty native analysis range")
    XCTAssertTrue(observed.1, "The private recording must be present during native progress")
    let url = try XCTUnwrap(observed.2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    if let instant = observed.3 {
      XCTAssertLessThan(instant.duration(to: .now), .seconds(10))
    }
    let fresh = try await synthesizer.synthesize(text: phrase)
    let text = try await AppleSpeechRecognizer().transcribe(audio: AudioInput(data: fresh.data))
    XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}
