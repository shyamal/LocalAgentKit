import ArgumentParser
import Foundation
import LocalAgentKitCore
import LocalAgentKitEvalSupport
import LocalAgentKitProviders
import LocalAgentKitTesting

@main
struct EvalCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "LocalAgentKitEval", abstract: "Inspect and run local model evaluation suites.",
    subcommands: [List.self, Run.self], defaultSubcommand: List.self)

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List bundled suites without using a model.")
    func run() throws {
      let tools = try SuiteLoader.tools()
      print(
        "Tool catalog: \(tools.count) tools, \(tools.filter(\.needsConfirmation).count) needing confirmation"
      )
      for name in SuiteLoader.phase0Names {
        let suite = try SuiteLoader.suite(named: name)
        print("\(name): \(suite.goalCount) goals (\(suite.task))")
      }
      print(
        "Single-call probes: single-tool, refusal. Multi-step and context-load runners are pending."
      )
    }
  }

  enum Model: String, ExpressibleByArgument { case mock, foundation }

  struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Capture responses without executing tools.")
    @Option(help: "Suite: single-tool or refusal.") var suite = "single-tool"
    @Option(help: "mock is a synthetic smoke check; foundation uses the on-device model.")
    var model: Model = .mock
    @Option(help: "Maximum goals to run.") var limit: Int?
    @Option(help: "Run one goal by its ID.") var goal: String?
    @Option(help: "Repetitions per goal (1...100).") var repetitions = 1
    @Option(help: "Per-probe deadline in seconds.") var timeout: Double = 60
    @Option(help: "JSON output path. Omit to write to stdout.") var output: String?

    mutating func validate() throws {
      guard timeout.isFinite, timeout > 0, timeout <= 3600 else {
        throw ValidationError("Timeout must be finite, positive, and at most 3600 seconds.")
      }
      guard (1...100).contains(repetitions), limit.map({ $0 > 0 }) ?? true else {
        throw ValidationError("Repetitions must be 1...100 and limit must be positive.")
      }
      guard ["single-tool", "refusal"].contains(suite) else {
        throw ValidationError("Supported probe suites: single-tool, refusal.")
      }
    }

    func run() async throws {
      let provider: any LocalModelProvider
      switch model {
      case .mock:
        provider = MockModelProvider(handler: { _ in .text("Synthetic harness smoke response.") })
      case .foundation: provider = FoundationModelProvider(maxDecodingRetries: 0)
      }
      let results = try await ProbeRunner.run(
        suiteName: suite, model: provider,
        repetitions: repetitions, limit: limit, goalID: goal, timeout: .seconds(timeout))
      let report = Report(
        schemaVersion: 1, mode: "single-call-probe", model: model.rawValue,
        synthetic: model == .mock,
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        createdAt: Date(), suite: try SuiteLoader.suite(named: suite), results: results)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      var data = try encoder.encode(report)
      data.append(0x0A)
      if let output {
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
      } else {
        FileHandle.standardOutput.write(data)
      }
      if results.contains(where: { $0.outcome == .failure }) { throw ExitCode.failure }
    }
  }
}

private struct Report: Encodable {
  let schemaVersion: Int
  let mode: String
  let model: String
  let synthetic: Bool
  let operatingSystem: String
  let createdAt: Date
  let suite: SuiteLoader.Suite
  let results: [ProbeResult]

  enum CodingKeys: CodingKey {
    case schemaVersion, mode, model, synthetic, operatingSystem, createdAt, suite, suiteVersion,
      context, results
  }
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(mode, forKey: .mode)
    try container.encode(model, forKey: .model)
    try container.encode(synthetic, forKey: .synthetic)
    try container.encode(operatingSystem, forKey: .operatingSystem)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(suite.name, forKey: .suite)
    try container.encode(suite.version, forKey: .suiteVersion)
    if let context = suite.context {
      try container.encode(
        [
          "referenceDateTime": context.referenceDateTime,
          "referenceWeekday": context.referenceWeekday, "timeZone": context.timeZone,
          "locale": context.locale,
        ], forKey: .context)
    }
    try container.encode(results, forKey: .results)
  }
}
