import CryptoKit
import Foundation
import SwiftUI

@main
struct EmbeddingProbeApp: App {
  @State private var status =
    "Embeds bundled synthetic English text only. No personal data is read."
  @State private var running = false
  @State private var operation: Task<Void, Never>?
  var body: some Scene {
    WindowGroup {
      VStack(spacing: 16) {
        Text("Embedding device probe").font(.title)
        Text(status).textSelection(.enabled)
        if running { ProgressView() }
        Button("Run bundled benchmark") { start() }.disabled(running)
        Button("Cancel") { operation?.cancel() }.disabled(!running)
      }
      .padding()
      .task {
        if ProcessInfo.processInfo.environment["LOCALAGENTKIT_EMBEDDING_AUTORUN"] == "1" { start() }
      }
    }
  }
  @MainActor private func start() {
    guard !running else { return }
    running = true
    status = "Measuring local assets…"
    operation = Task {
      defer {
        running = false
        operation = nil
      }
      do {
        guard let url = Bundle.main.url(forResource: "corpus", withExtension: "json") else {
          throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        let corpus = try JSONDecoder().decode(ProbeCorpus.self, from: data)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let runID =
          ProcessInfo.processInfo.environment["LOCALAGENTKIT_EMBEDDING_RUN_ID"]
          .flatMap(UUID.init(uuidString:)) ?? UUID()
        let native = NativeEmbeddingPaths()
        var report = try await ProbeRunner.run(
          corpus: corpus, digest: digest, paths: native.paths(),
          metadata: [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalMemoryBytes": String(ProcessInfo.processInfo.physicalMemory),
            "thermalStart": String(describing: ProcessInfo.processInfo.thermalState),
            "measurement": "App-bundle assets; not a controlled latency/energy benchmark",
          ], runID: runID)
        if ProcessInfo.processInfo.environment["LOCALAGENTKIT_COREAI_PROBE"] == "1" {
          if #available(iOS 27.0, *) {
            let documents = try FileManager.default.url(
              for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            status = "Loading converted Core AI model and checking numerical parity…"
            report.coreAI = try await CoreAIEmbeddingProbe().run(
              directory: documents.appendingPathComponent("CoreAI", isDirectory: true),
              corpus: corpus, digest: digest)
          } else {
            report.coreAI = CoreAIProbeResult(
              status: "unavailable-os", failure: "Core AI requires iOS 27", comparedVectorCount: 0,
              maximumAbsoluteError: nil, metadata: [:], export: nil)
          }
        }
        report.metadata["thermalEnd"] = String(describing: ProcessInfo.processInfo.thermalState)
        try Task.checkCancellation()
        let directory = try FileManager.default.url(
          for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let output = directory.appendingPathComponent("embedding-report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(report).write(to: output, options: .atomic)
        status =
          "Saved run \(runID.uuidString) to Documents/embedding-report.json. "
          + report.results.map { "\($0.path): \($0.status.rawValue)" }.joined(separator: "; ")
        if let coreAI = report.coreAI {
          status += "; Core AI: \(coreAI.status)"
          if let failure = coreAI.failure { status += " (\(failure))" }
        }
      } catch is CancellationError {
        status = "Cancelled; no new report saved."
      } catch {
        status = "Probe failed; no new report saved: \(error)"
      }
    }
  }
}
