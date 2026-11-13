import AVFAudio
import Foundation
import LocalAgentKitCore
import Speech

/// Transcribes recorded audio locally using installed SpeechTranscriber assets.
/// The host owns audio authorization, capture and asset provisioning.
public struct AppleSpeechRecognizer: SpeechRecognizer {
  /// Uses locally installed models and never requests asset installation.
  public let requiresNetwork = false
  /// Requested BCP-47 locale, resolved against native support at transcription time.
  public let localeIdentifier: String
  private let maximumBytes: Int
  private let maximumDuration: Double
  private let maximumCharacters: Int
  private let recognize: @Sendable (URL, String, Int) async throws -> String

  /// Creates a recognizer with defaults of 16 MiB, 60 seconds and 20,000 transcript characters.
  public init(
    localeIdentifier: String = "en-US", maximumBytes: Int = 16 * 1024 * 1024,
    maximumDuration: Double = 60, maximumCharacters: Int = 20_000
  ) throws {
    try self.init(
      localeIdentifier: localeIdentifier, maximumBytes: maximumBytes,
      maximumDuration: maximumDuration, maximumCharacters: maximumCharacters,
      recognize: Self.recognize)
  }

  init(
    localeIdentifier: String = "en-US", maximumBytes: Int = 16 * 1024 * 1024,
    maximumDuration: Double = 60, maximumCharacters: Int = 20_000,
    recognize: @escaping @Sendable (URL, String, Int) async throws -> String
  ) throws {
    guard !localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      maximumBytes > 0, maximumDuration.isFinite, maximumDuration > 0, maximumCharacters > 0
    else {
      throw AgentError.invalidConfiguration(
        .invalidLimit("Invalid speech recognition configuration"))
    }
    self.localeIdentifier = localeIdentifier
    self.maximumBytes = maximumBytes
    self.maximumDuration = maximumDuration
    self.maximumCharacters = maximumCharacters
    self.recognize = recognize
  }

  /// Validates encoded size and decoded duration, then returns final transcript text.
  /// Uses a private temporary file and attempts removal after processing. Empty recognition is valid.
  public func transcribe(audio: AudioInput) async throws -> String {
    do {
      try Task.checkCancellation()
      guard !audio.data.isEmpty, audio.data.count <= maximumBytes else {
        throw AgentError.speechFailure("Audio is empty or exceeds the encoded byte limit")
      }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appendingPathComponent("recording.audio")
      try audio.data.write(to: url, options: .atomic)
      try Task.checkCancellation()
      try validateDuration(url)
      let text = try await recognize(url, localeIdentifier, maximumCharacters)
      try Task.checkCancellation()
      guard text.count <= maximumCharacters else {
        throw AgentError.speechFailure("Transcript exceeds the character limit")
      }
      return text
    } catch {
      if Task.isCancelled || error is CancellationError { throw AgentError.cancelled }
      if let error = error as? AgentError { throw error }
      throw AgentError.speechFailure("Recorded audio transcription failed")
    }
  }

  private func validateDuration(_ url: URL) throws {
    let file = try AVAudioFile(forReading: url)
    let rate = file.processingFormat.sampleRate
    let seconds = Double(file.length) / rate
    guard file.length > 0, rate.isFinite, rate > 0, file.processingFormat.channelCount > 0,
      seconds.isFinite, seconds <= maximumDuration
    else {
      throw AgentError.speechFailure("Audio has invalid dimensions or exceeds the duration limit")
    }
  }

  private static func recognize(_ url: URL, localeIdentifier: String, maximumCharacters: Int)
    async throws -> String
  {
    try Task.checkCancellation()
    guard SpeechTranscriber.isAvailable,
      let locale = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: localeIdentifier))
    else {
      throw AgentError.speechFailure("Speech recognition is unavailable for the requested locale")
    }
    try Task.checkCancellation()
    let transcriber = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    let status = await AssetInventory.status(forModules: [transcriber])
    try Task.checkCancellation()
    guard status == .installed else {
      throw AgentError.speechFailure(
        "Speech recognition assets are not installed for the requested locale")
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let results = transcriber.results
    let file = try AVAudioFile(forReading: url)
    return try await runSession(
      start: { try await analyzer.start(inputAudioFile: file, finishAfterFile: true) },
      read: {
        var text = ""
        for try await result in results {
          try Task.checkCancellation()
          if result.isFinal {
            let part = String(result.text.characters)
            guard part.count <= maximumCharacters - text.count else {
              throw AgentError.speechFailure("Transcript exceeds the character limit")
            }
            text += part
          }
        }
        return text
      },
      cancel: { await analyzer.cancelAndFinishNow() })
  }

  /// Runs file feeding and result consumption concurrently. Cancelling the analyzer before
  /// leaving the task group lets either side release the other after an error.
  static func runSession(
    start: @escaping @Sendable () async throws -> Void,
    read: @escaping @Sendable () async throws -> String,
    cancel: @escaping @Sendable () async -> Void
  ) async throws -> String {
    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: String?.self) { group in
        group.addTask {
          try await start()
          return nil
        }
        group.addTask { try await read() }
        do {
          var text = ""
          for try await result in group { if let result { text = result } }
          return text
        } catch {
          group.cancelAll()
          await cancel()
          throw error
        }
      }
    } onCancel: {
      Task { await cancel() }
    }
  }
}
