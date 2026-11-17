import Foundation
import Speech
import SwiftUI
import UIKit

@main struct MultimodalProbeApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var status =
    "Synthetic OCR and speech only. No camera, microphone or personal data access."
  @State private var operation: Task<Void, Never>?
  @State private var autoran = false
  @State private var confirmSpeechPreparation = false

  var body: some Scene {
    WindowGroup {
      VStack(spacing: 16) {
        Text("Multimodal resource probe").font(.title)
        Text(status).textSelection(.enabled)
        if operation != nil { ProgressView() }
        Button("Prepare English speech data") { confirmSpeechPreparation = true }
          .disabled(operation != nil)
        Button("Run 60-second phases") { start(seconds: nil) }.disabled(operation != nil)
        Button("Run battery protocol (20 minutes)") { start(seconds: 300) }.disabled(
          operation != nil)
        Text(
          "Battery evidence requires unplugging, stable brightness, and all observed samples discharging. Leave this screen open. Critical thermal state stops the run."
        )
        .font(.footnote)
        Button("Cancel") { operation?.cancel() }.disabled(operation == nil)
      }
      .padding()
      .confirmationDialog(
        "Prepare system speech data?", isPresented: $confirmSpeechPreparation,
        titleVisibility: .visible
      ) {
        Button("Download system speech data") { prepareSpeechData() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "This explicit setup may download English speech models using your connection. Setup is outside measured phases; running the probe never requests installation."
        )
      }
      .task { autorunIfReady() }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active { operation?.cancel() } else { autorunIfReady() }
      }
    }
  }

  @MainActor private func prepareSpeechData() {
    guard operation == nil else { return }
    status = "Preparing English speech data outside measurement…"
    operation = Task {
      defer { operation = nil }
      do {
        guard SpeechTranscriber.isAvailable,
          let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "en-US"))
        else {
          status = "English transcription is unavailable on this device."
          return
        }
        try Task.checkCancellation()
        let module = SpeechTranscriber(
          locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
        try await withTaskCancellationHandler {
          try Task.checkCancellation()
          try await request?.downloadAndInstall()
          try Task.checkCancellation()
        } onCancel: {
          request?.progress.cancel()
        }
        let installed = await AssetInventory.status(forModules: [module]) == .installed
        try Task.checkCancellation()
        status =
          installed
          ? "Local English speech data is ready. Start a fresh measurement run."
          : "Speech data is not installed. No transcription measurement is available."
      } catch {
        status =
          Task.isCancelled
          ? "Speech setup stopped. System work may finish separately; recheck before measuring."
          : "Speech setup failed: \(error)"
      }
    }
  }

  @MainActor private func autorunIfReady() {
    let env = ProcessInfo.processInfo.environment
    guard scenePhase == .active, !autoran, env["LOCALAGENTKIT_RESOURCE_AUTORUN"] == "1" else {
      return
    }
    autoran = true
    start(
      seconds: env["LOCALAGENTKIT_RESOURCE_SECONDS"].flatMap(Int.init),
      runID: env["LOCALAGENTKIT_RESOURCE_RUN_ID"].flatMap(UUID.init(uuidString:)) ?? UUID())
  }

  @MainActor private func start(seconds: Int?, runID: UUID = UUID()) {
    guard operation == nil else { return }
    status = "Preparing synthetic fixtures and checking installed assets…"
    operation = Task {
      let device = UIDevice.current
      let oldMonitoring = device.isBatteryMonitoringEnabled
      let oldIdle = UIApplication.shared.isIdleTimerDisabled
      device.isBatteryMonitoringEnabled = true
      UIApplication.shared.isIdleTimerDisabled = true
      defer {
        device.isBatteryMonitoringEnabled = oldMonitoring
        UIApplication.shared.isIdleTimerDisabled = oldIdle
        operation = nil
      }
      var log: ResourceLog?
      do {
        guard let url = Bundle.main.url(forResource: "workload", withExtension: "json") else {
          throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(WorkloadFixture.self, from: data)
        let plan = try ResourcePlan(
          secondsPerPhase: seconds ?? fixture.secondsPerPhase,
          intervalMilliseconds: fixture.intervalMilliseconds)
        let prepared = try await NativeWorkloads.prepare(fixture, digest: NativeWorkloads.sha(data))
        let documents = try FileManager.default.url(
          for: .documentDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true)
        let target = documents.appendingPathComponent("resource-\(runID.uuidString).jsonl")
        let sink = try ResourceLog(url: target)
        log = sink
        var metadata = prepared.metadata
        metadata["startedAt"] = ISO8601DateFormatter().string(from: Date())
        #if DEBUG
          metadata["configuration"] =
            "Debug; standalone providers; sequential paced synthetic fixture"
        #else
          metadata["configuration"] =
            "Release; standalone providers; sequential paced synthetic fixture"
        #endif
        try await ResourceProbe().run(
          plan: plan, workloads: prepared.workloads, runID: runID,
          metadata: metadata, sample: { await DeviceSampling.take() },
          emit: { event in
            try await sink.append(event)
            await MainActor.run { status = "\(event.kind): \(event.path?.rawValue ?? "run")" }
          })
        try await sink.close()
        log = nil
        status =
          "Finished. Report: \(target.lastPathComponent). Inspect path availability and battery eligibility on the host."
      } catch {
        try? await log?.close()
        status = "Stopped: \(error). Partial logs are not complete measurements."
      }
    }
  }
}
