import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders
import SwiftUI
import UIKit

// The developer-only harness sources compile directly into this host. Keep evaluation
// support out of the SDK's exported library products and retain the exact fixture folder.
extension Bundle {
  static var module: Bundle { .main }
}

@main struct PlanningProbeApp: App {
  @Environment(\.scenePhase) private var phase
  @State private var operation: Task<Void, Never>?
  @State private var autoran = false
  @State private var status = "Synthetic fixtures only. No personal tools or files are accessed."

  var body: some Scene {
    WindowGroup {
      VStack(spacing: 20) {
        Text("Planning measurement").font(.title)
        Text(status).textSelection(.enabled)
        Text(
          "Leave this screen open. Model-driven: 30 trials; state-machine: 30; single-tool: 100. Results never change the default automatically."
        )
        .font(.footnote)
        Button("Run fixed planning protocol") { start() }.disabled(operation != nil)
        Button("Cancel") { operation?.cancel() }.disabled(operation == nil)
        if operation != nil { ProgressView() }
      }
      .padding()
      .task { autorun() }
      .onChange(of: phase) { _, value in
        if value != .active { operation?.cancel() } else { autorun() }
      }
    }
  }

  @MainActor private func autorun() {
    let env = ProcessInfo.processInfo.environment
    guard phase == .active, !autoran, env["LOCALAGENTKIT_PLANNING_AUTORUN"] == "1" else { return }
    autoran = true
    start(id: env["LOCALAGENTKIT_PLANNING_RUN_ID"].flatMap(UUID.init(uuidString:)) ?? UUID())
  }

  @MainActor private func start(id: UUID = UUID()) {
    guard operation == nil else { return }
    operation = Task {
      let oldIdle = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      defer {
        UIApplication.shared.isIdleTimerDisabled = oldIdle
        operation = nil
      }
      do {
        let documents = try FileManager.default.url(
          for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("planning-\(id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try save(
          [
            "runID": id.uuidString,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "configuration": Self.configuration,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "order": "modelDriven-bounded-v1,stateMachine-open,single-tool",
            "thermalStart": String(describing: ProcessInfo.processInfo.thermalState),
          ], at: directory.appendingPathComponent("started.json"))
        let model = FoundationModelProvider(maxDecodingRetries: 0)
        let suite = try SuiteLoader.suite(named: "multi-step")
        for choice: PlannerChoice in [.modelDriven, .stateMachine] {
          try Task.checkCancellation()
          let identity = choice == .modelDriven ? "modelDriven-bounded-v1" : "stateMachine-open"
          status = "Running \(identity): 30 trials. Leave this screen open."
          let results = try await MultiStepRunner.run(
            model: model, repetitions: 3, timeout: .seconds(60), planner: choice)
          try Task.checkCancellation()
          let assessment = try await M5Assessment.assess(
            results, synthetic: false, repetitions: 3, planner: choice)
          let report = PhoneMultiReport(
            planner: identity,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            suite: suite.name, suiteVersion: suite.version, context: suite.context,
            results: results, m5: assessment, attempts: results.count,
            completed: results.filter { $0.score.completed }.count,
            completionRate: results.isEmpty
              ? nil : Double(results.filter { $0.score.completed }.count) / Double(results.count))
          try save(report, at: directory.appendingPathComponent(identity + ".json"))
        }
        status = "Running single-tool validity: 100 probes. Leave this screen open."
        let rows = try await ProbeRunner.run(
          suiteName: "single-tool", model: model, repetitions: 5, timeout: .seconds(60))
        try Task.checkCancellation()
        let scorer = try ToolValidityScorer(tools: SuiteLoader.tools())
        let scores = try scorer.score(rows)
        let singleSuite = try SuiteLoader.suite(named: "single-tool")
        let report = PhoneSingleReport(
          operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
          suite: singleSuite.name, suiteVersion: singleSuite.version, context: singleSuite.context,
          results: rows,
          validity: scores, validitySummary: scorer.summary(scores))
        try save(report, at: directory.appendingPathComponent("single-tool.json"))
        try save(
          [
            "runID": id.uuidString, "finishedAt": ISO8601DateFormatter().string(from: Date()),
            "terminal": "finished",
            "thermalEnd": String(describing: ProcessInfo.processInfo.thermalState),
          ], at: directory.appendingPathComponent("finished.json"))
        status = "Finished. Report: planning-\(id.uuidString). Review raw results on the host."
      } catch {
        status = "Stopped: \(error). Missing phases or finished marker are incomplete evidence."
      }
    }
  }

  private static var configuration: String {
    #if DEBUG
      "Debug"
    #else
      "Release"
    #endif
  }
  private func save<T: Encodable>(_ value: T, at url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .withoutOverwriting)
  }
}

private struct PhoneMultiReport: Encodable {
  let schemaVersion = 3
  let measurementProtocolVersion = 1
  let mode = "agent-run"
  let model = "foundation"
  let synthetic = false
  let createdAt = Date()
  let timeoutSeconds = 60
  let repetitions = 3
  let planner: String
  let operatingSystem: String
  let suite: String
  let suiteVersion: Int
  let context: SuiteLoader.Suite.Context?
  let results: [MultiStepResult]
  let m5: M5Assessment
  let attempts: Int
  let completed: Int
  let completionRate: Double?
}

private struct PhoneSingleReport: Encodable {
  let schemaVersion = 2
  let measurementProtocolVersion = 1
  let mode = "single-call-probe"
  let model = "foundation"
  let synthetic = false
  let createdAt = Date()
  let timeoutSeconds = 60
  let repetitions = 5
  let operatingSystem: String
  let suite: String
  let suiteVersion: Int
  let context: SuiteLoader.Suite.Context?
  let results: [ProbeResult]
  let validity: [ToolValidityScore]
  let validitySummary: ToolValiditySummary
}
