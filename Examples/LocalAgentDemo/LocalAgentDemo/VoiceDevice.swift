#if os(iOS)
  import AVFAudio
  import Foundation
  import LocalAgentKitCore
  import Observation
  import Speech

  @MainActor @Observable final class VoiceAssets {
    private(set) var ready = false
    private(set) var preparing = false
    private(set) var status = "Checking English (US) speech data…"
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var request: AssetInstallationRequest?
    @ObservationIgnored private var revision = UUID()

    func check() async {
      let token = revision
      do {
        let module = try await transcriber()
        let state = await AssetInventory.status(forModules: [module])
        guard revision == token, !Task.isCancelled else { return }
        ready = state == .installed
        status =
          ready
          ? "Local English speech data is ready." : "Local English speech data needs preparation."
      } catch {
        guard revision == token else { return }
        ready = false
        status = String(describing: error)
      }
    }

    func prepare() {
      guard !preparing else { return }
      preparing = true
      ready = false
      status = "Downloading/installing system speech data…"
      let token = revision
      task = Task {
        do {
          let module = try await transcriber()
          try Task.checkCancellation()
          // Installation requests manage locale reservations; no automatic download occurs in check().
          let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
          guard revision == token, !Task.isCancelled else { return }
          self.request = request
          try await withTaskCancellationHandler {
            try await request?.downloadAndInstall()
          } onCancel: {
            request?.progress.cancel()
          }
          try Task.checkCancellation()
          await check()
        } catch {
          guard revision == token else { return }
          status =
            Task.isCancelled
            ? "Speech preparation stopped. System work may finish separately."
            : "Speech preparation failed: \(error)"
        }
        guard revision == token else { return }
        preparing = false
        request = nil
        task = nil
      }
    }

    func cancel() {
      revision = UUID()
      request?.progress.cancel()
      task?.cancel()
      request = nil
      task = nil
      if preparing { status = "Preparation stopped. Check speech data before trying again." }
      preparing = false
    }

    private func transcriber() async throws -> SpeechTranscriber {
      guard SpeechTranscriber.isAvailable,
        let locale = await SpeechTranscriber.supportedLocale(
          equivalentTo: Locale(identifier: "en-US"))
      else {
        throw AgentError.speechFailure("English transcription is unavailable on this device.")
      }
      try Task.checkCancellation()
      return SpeechTranscriber(
        locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }
  }

  /// Capture/playback ownership stays on the main actor; no native audio object crosses a task.
  @MainActor @Observable final class VoiceAudioDevice {
    private(set) var recording = false
    private(set) var requestingPermission = false
    private(set) var failure: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var completion:
      (@MainActor (Result<AudioInput, any Error>) -> Void)?
    @ObservationIgnored private var captureID = UUID()
    @ObservationIgnored private var playbackID = UUID()

    func record(completion: @escaping @MainActor (Result<AudioInput, any Error>) -> Void) {
      cancel()
      failure = nil
      requestingPermission = true
      let token = captureID
      recordingTask = Task {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard captureID == token, !Task.isCancelled else { return }
        requestingPermission = false
        guard granted else {
          failure =
            "Microphone access was denied. You can allow it in Settings or choose an audio file."
          return
        }
        do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
          try session.setActive(true)
          let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voice-" + UUID().uuidString)
          try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
          self.directory = directory
          let recorder = try AVAudioRecorder(
            url: directory.appendingPathComponent("question.wav"),
            settings: [
              AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
              AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
              AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ])
          self.recorder = recorder
          self.completion = completion
          guard recorder.record(forDuration: 15) else {
            throw AgentError.speechFailure("Could not start recording.")
          }
          recording = true
          while recorder.isRecording {
            try await Task.sleep(for: .milliseconds(100))
            guard captureID == token else { return }
          }
          guard captureID == token, !Task.isCancelled else { return }
          finishRecording()
        } catch {
          guard captureID == token, !Task.isCancelled else { return }
          cancel()
          failure = "Recording stopped: \(error)"
        }
      }
    }

    func finishRecording() {
      guard let recorder, let directory else { return }
      let completion = completion
      self.completion = nil
      self.recorder = nil
      self.directory = nil
      recording = false
      recordingTask?.cancel()
      recordingTask = nil
      recorder.stop()
      defer {
        try? FileManager.default.removeItem(at: directory)
        deactivate()
      }
      do {
        let data = try Data(contentsOf: recorder.url)
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024 else {
          throw AgentError.speechFailure("Recording was empty or too large.")
        }
        completion?(.success(AudioInput(data: data)))
      } catch { completion?(.failure(error)) }
    }

    func play(_ audio: AudioOutput) async throws {
      stopPlayback()
      let token = playbackID
      let player = try AVAudioPlayer(data: audio.data)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback)
      try session.setActive(true)
      self.player = player
      defer {
        player.stop()
        if playbackID == token {
          self.player = nil
          deactivate()
        }
      }
      guard player.play() else {
        throw AgentError.speechFailure("Could not play the spoken answer.")
      }
      while player.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
      try Task.checkCancellation()
    }

    func stopPlayback() {
      playbackID = UUID()
      player?.stop()
      player = nil
      deactivate()
    }

    func clearFailure() { failure = nil }

    func cancel() {
      failure = nil
      captureID = UUID()
      recordingTask?.cancel()
      recordingTask = nil
      completion = nil
      recorder?.stop()
      recorder = nil
      recording = false
      requestingPermission = false
      if let directory { try? FileManager.default.removeItem(at: directory) }
      directory = nil
      stopPlayback()
    }

    private func deactivate() {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }
#endif
