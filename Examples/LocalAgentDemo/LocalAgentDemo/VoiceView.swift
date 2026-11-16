#if os(iOS)
  import Foundation
  import LocalAgentKitCore
  import LocalAgentKitProviders
  import SwiftUI
  import UniformTypeIdentifiers

  struct VoiceDemoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var assets = VoiceAssets()
    @State private var audio = VoiceAudioDevice()
    @State private var controller: VoiceController?
    @State private var setupFailure: String?
    @State private var downloadConfirmation = false
    @State private var importing = false
    @State private var sampleTask: Task<Void, Never>?
    @State private var sampling = false
    @State private var loadRevision = UUID()

    var body: some View {
      NavigationStack {
        Form {
          Section("Local English voice") {
            Text(
              "Record up to 15 seconds, review the transcript, then ask and hear the answer. Audio, transcripts and replies are not saved by this screen."
            )
            .font(.caption)
            Text(assets.status)
            if assets.preparing {
              ProgressView("Preparing speech…")
            } else if !assets.ready {
              Button("Prepare English speech data") { downloadConfirmation = true }
            }
            Button("Check speech data") { Task { await assets.check() } }.disabled(assets.preparing)
            Text(
              "Preparation can download system speech data using your connection. Recording and recognition use local processing once ready."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          if let controller {
            Section("Question") {
              if audio.recording {
                Label("Recording — stops after 15 seconds", systemImage: "mic.fill")
                Button("Stop recording") { audio.finishRecording() }
              } else {
                Button("Record question") {
                  cancel(clearText: true)
                  audio.record { result in
                    switch result {
                    case .success(let input): controller.transcribe(input)
                    case .failure(let error): setupFailure = String(describing: error)
                    }
                  }
                }.disabled(
                  !assets.ready || controller.busy || audio.requestingPermission || sampling)
              }
              if audio.requestingPermission { ProgressView("Requesting microphone access…") }
              Button("Choose short audio file") { importing = true }
                .disabled(!assets.ready || controller.busy || audio.recording || sampling)
              Button("Try generated sample question") { runSample(controller) }
                .disabled(!assets.ready || controller.busy || audio.recording || sampling)
              if sampling { ProgressView("Preparing sample recording…") }
              if controller.busy { ProgressView(controller.stage.rawValue.capitalized + "…") }
              TextField(
                "Review or correct the recognized question",
                text: Binding(
                  get: { controller.transcript }, set: { controller.transcript = $0 }),
                axis: .vertical
              )
              .disabled(controller.busy || audio.recording || sampling)
              Button("Ask and speak") {
                setupFailure = nil
                audio.clearFailure()
                controller.askAndSpeak()
              }
              .disabled(
                controller.busy
                  || controller.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || audio.recording || sampling)
            }
            if !controller.response.isEmpty {
              Section("Answer") {
                Text("Question: " + controller.submittedQuestion).font(.caption).foregroundStyle(
                  .secondary)
                Text(controller.response).textSelection(.enabled)
                Button("Replay answer") {
                  setupFailure = nil
                  audio.clearFailure()
                  controller.replay()
                }.disabled(
                  controller.busy || audio.recording)
              }
            }
            if controller.busy || audio.recording || audio.requestingPermission || sampling {
              Button("Stop / cancel") { cancel() }
            }
            if let failure = setupFailure ?? audio.failure ?? controller.failure {
              Text(failure).foregroundStyle(.red)
            }
          } else if let setupFailure {
            Text(setupFailure).foregroundStyle(.red)
          }
        }
        .navigationTitle("Voice question")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
              cancel(clearText: true)
              assets.cancel()
              dismiss()
            }
          }
          ToolbarItem(placement: .primaryAction) {
            if controller?.busy == true || audio.recording || audio.requestingPermission || sampling
              || assets.preparing
            {
              Button("Stop") {
                cancel()
                assets.cancel()
              }
            }
          }
        }
        .confirmationDialog("Prepare English speech data?", isPresented: $downloadConfirmation) {
          Button("Download system speech data") { assets.prepare() }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(
            "The system may download language models from Apple. This is separate from the agent's offline run; no recording is sent for this preparation."
          )
        }
        .task {
          guard controller == nil else { return }
          do {
            controller = try VoiceController(
              recognizer: AppleSpeechRecognizer(
                maximumBytes: 2 * 1024 * 1024, maximumDuration: 16, maximumCharacters: 1000),
              synthesizer: AppleSpeechSynthesizer(),
              makeRuntime: { try VoiceSession.runtime(model: FoundationModelProvider()) },
              play: { try await audio.play($0) }, stop: { audio.stopPlayback() })
            await assets.check()
          } catch { setupFailure = String(describing: error) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
          guard let controller else { return }
          switch result {
          case .success(let url):
            cancel(clearText: true)
            sampling = true
            let token = loadRevision
            sampleTask = Task {
              do {
                let data = try await Task.detached {
                  guard url.isFileURL else {
                    throw AgentError.speechFailure("Choose a local audio file.")
                  }
                  let access = url.startAccessingSecurityScopedResource()
                  defer { if access { url.stopAccessingSecurityScopedResource() } }
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                  guard size <= 2 * 1024 * 1024 else {
                    throw AgentError.speechFailure("Choose audio up to 2 MiB and 15 seconds.")
                  }
                  return try Data(contentsOf: url)
                }.value
                try Task.checkCancellation()
                guard loadRevision == token else { return }
                controller.transcribe(AudioInput(data: data))
              } catch { if !Task.isCancelled { setupFailure = String(describing: error) } }
              guard loadRevision == token else { return }
              sampling = false
              sampleTask = nil
            }
          case .failure: setupFailure = "Could not open the audio selection."
          }
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .background {
            cancel()
            assets.cancel()
          }
        }
        .onDisappear {
          cancel(clearText: true)
          assets.cancel()
        }
      }
    }

    private func runSample(_ controller: VoiceController) {
      cancel(clearText: true)
      sampling = true
      let token = loadRevision
      sampleTask = Task {
        do {
          let synthesizer = try AppleSpeechSynthesizer(maximumDuration: 15)
          let output = try await synthesizer.synthesize(text: "What is two plus two?")
          try Task.checkCancellation()
          guard loadRevision == token else { return }
          controller.transcribe(AudioInput(data: output.data))
        } catch { if !Task.isCancelled { setupFailure = String(describing: error) } }
        guard loadRevision == token else { return }
        sampling = false
        sampleTask = nil
      }
    }

    private func cancel(clearText: Bool = false) {
      loadRevision = UUID()
      sampleTask?.cancel()
      sampleTask = nil
      sampling = false
      controller?.cancel(clearText: clearText)
      audio.cancel()
      setupFailure = nil
    }
  }
#endif
