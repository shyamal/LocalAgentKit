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
    subcommands: [List.self, Run.self, ReviewRefusals.self, Compare.self, AssessM5.self],
    defaultSubcommand: List.self)

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List bundled suites without using a model.")
    func run() throws {
      let tools = try SuiteLoader.tools()
      print(
        "Tool catalog: \(tools.count) tools, \(tools.filter(\.needsConfirmation).count) needing confirmation"
      )
      for name in SuiteLoader.phase0Names + ["notes-local", "contacts-local"] {
        let suite = try SuiteLoader.suite(named: name)
        print("\(name): \(suite.goalCount) goals (\(suite.task))")
      }
      print(
        "Single-call probes: single-tool, refusal. Agent runs: multi-step. Budgeted probes: context-load."
      )
    }
  }

  enum Model: String, ExpressibleByArgument { case mock, foundation }
  enum ContextTools: String, ExpressibleByArgument {
    case both
    case contextOnly = "context-only"
    case registered
  }

  struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Run model probes or fixture-backed agent evaluations.")
    @Option(
      help: "Suite: single-tool, refusal, multi-step, context-load, notes-local or contacts-local.")
    var suite =
      "single-tool"
    @Option(help: "mock is a synthetic smoke check; foundation uses the on-device model.")
    var model: Model = .mock
    @Option(help: "Context-load profile ID (all by default).") var profile: String?
    @Option(help: "Context-load tools: both, context-only, registered.")
    var toolMode: ContextTools = .both
    @Option(help: "Maximum goals or context probes per profile to run.") var limit: Int?
    @Option(help: "Run one goal or context probe by its ID.") var goal: String?
    @Option(help: "Repetitions per goal (1...100); defaults to 5 for refusal, 1 otherwise.")
    var repetitions: Int?
    @Option(help: "Per-goal deadline in seconds.") var timeout: Double = 60
    @Option(help: "JSON output path. Omit to write to stdout.") var output: String?
    @Option(
      help: "Write pending soft-refusal review decisions with null answers (refusal suite only).")
    var reviewTemplate: String?

    mutating func validate() throws {
      if suite != "context-load" && (profile != nil || toolMode != .both) {
        throw ValidationError("Profile and tool-mode options apply only to context-load.")
      }
      if reviewTemplate != nil && suite != "refusal" {
        throw ValidationError("Review templates apply only to the refusal suite.")
      }
      if let reviewTemplate, let output,
        URL(fileURLWithPath: reviewTemplate).standardizedFileURL
          == URL(fileURLWithPath: output).standardizedFileURL
      {
        throw ValidationError("Report and review template need different output paths.")
      }
      guard timeout.isFinite, timeout > 0, timeout <= 3600 else {
        throw ValidationError("Timeout must be finite, positive, and at most 3600 seconds.")
      }
      guard repetitions.map({ (1...100).contains($0) }) ?? true, limit.map({ $0 > 0 }) ?? true
      else {
        throw ValidationError("Repetitions must be 1...100 and limit must be positive.")
      }
      guard
        ["single-tool", "refusal", "multi-step", "context-load", "notes-local", "contacts-local"]
          .contains(suite)
      else {
        throw ValidationError(
          "Supported suites: single-tool, refusal, multi-step, context-load, notes-local, contacts-local."
        )
      }
    }

    func run() async throws {
      let count = repetitions ?? (suite == "refusal" ? 5 : 1)
      let provider: any LocalModelProvider
      switch model {
      case .mock:
        provider = MockModelProvider(handler: { request in
          .text(
            request.tools.first?.name == "choose_next_action"
              ? "finish" : "Synthetic harness smoke response.")
        })
      case .foundation: provider = FoundationModelProvider(maxDecodingRetries: 0)
      }
      if suite == "context-load" {
        let modes: [ContextLoadResult.ToolMode]
        switch toolMode {
        case .both: modes = ContextLoadResult.ToolMode.allCases
        case .contextOnly: modes = [.contextOnly]
        case .registered: modes = [.registered]
        }
        let results = try await ContextLoadRunner.run(
          model: provider, repetitions: count, limit: limit, profileID: profile,
          probeID: goal, toolModes: modes, timeout: .seconds(timeout))
        let fixture = try SuiteLoader.contextFixture()
        let groups = Dictionary(grouping: results) { "\($0.profileID)/\($0.toolMode.rawValue)" }
        try write(
          ContextReport(
            schemaVersion: 5, mode: "sdk-budgeted-context", model: model.rawValue,
            synthetic: model == .mock,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            createdAt: Date(), fixture: fixture.fixture, fixtureVersion: fixture.version,
            repetitions: count, timeoutSeconds: timeout,
            budget: ["systemAndTools": 0.30, "conversation": 0.40, "rag": 0.20, "plan": 0.10],
            outputReserveTokens: 512, results: results, summary: ContextLoadSummary(results),
            groups: groups.mapValues(ContextLoadSummary.init)), to: output)
        if results.contains(where: { $0.outcome == .otherError || $0.outcome == .timeout }) {
          throw ExitCode.failure
        }
        return
      }
      if suite == "multi-step" {
        let results = try await MultiStepRunner.run(
          model: provider, repetitions: count,
          limit: limit, goalID: goal, timeout: .seconds(timeout))
        let metadata = try SuiteLoader.suite(named: "multi-step")
        let completed = results.filter { $0.score.completed }.count
        let report = MultiReport(
          schemaVersion: 3, mode: "agent-run", planner: "stateMachine-open",
          model: model.rawValue, synthetic: model == .mock,
          operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
          createdAt: Date(), suite: metadata.name, suiteVersion: metadata.version,
          context: metadata.context, timeoutSeconds: timeout, repetitions: count,
          results: results, attempts: results.count, completed: completed,
          completionRate: results.isEmpty ? nil : Double(completed) / Double(results.count),
          m5: try await M5Assessment.assess(
            results, synthetic: model == .mock, repetitions: count, timeoutSeconds: timeout))
        try write(report, to: output)
        // Completion misses are outcomes; unavailable models and timeouts remain visible failures.
        if results.contains(where: { ["modelUnavailable", "timeout"].contains($0.stopReason) }) {
          throw ExitCode.failure
        }
        return
      }
      let results = try await ProbeRunner.run(
        suiteName: suite, model: provider,
        repetitions: count, limit: limit, goalID: goal, timeout: .seconds(timeout))
      if suite == "refusal" {
        let report = try RefusalReport.make(
          results: results, model: model.rawValue,
          synthetic: model == .mock, repetitions: count, timeoutSeconds: timeout)
        try write(report, to: output)
        if let reviewTemplate {
          let pending = report.assessment.scores.filter {
            !$0.matchedMarkers.isEmpty && $0.reviewedSoftRefusal == nil
          }.map { score in
            JSONValue.object([
              "goalID": .string(score.goalID), "repetition": .int(score.repetition),
              "text": .string(
                report.results.first {
                  $0.goalID == score.goalID && $0.repetition == score.repetition
                }?.text ?? ""),
              "isRefusal": .null,
            ])
          }
          try write(
            JSONValue.object(["reportID": .string(report.reportID), "decisions": .array(pending)]),
            to: reviewTemplate)
        }
        try finishRefusal(report.assessment)
        return
      }
      let scorer = try ToolValidityScorer(tools: SuiteLoader.tools())
      let scores = try scorer.score(results)
      let report = Report(
        schemaVersion: 2, mode: "single-call-probe", model: model.rawValue,
        synthetic: model == .mock,
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        createdAt: Date(), suite: try SuiteLoader.suite(named: suite),
        results: results, timeoutSeconds: timeout, repetitions: count,
        validity: scores, validitySummary: scorer.summary(scores))
      try write(report, to: output)
      if results.contains(where: { $0.outcome == .failure }) { throw ExitCode.failure }
    }
  }

  struct AssessM5: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "assess-m5",
      abstract: "Replay M5 evidence from a saved multi-step report without model calls.")
    @Option(help: "Saved schema-3 multi-step report.") var report: String
    @Option(help: "Assessment JSON output path; omit for stdout.") var output: String?
    mutating func validate() throws {
      if let output,
        URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
          == URL(fileURLWithPath: report).standardizedFileURL.resolvingSymlinksInPath()
      {
        throw ValidationError("Assessment output must not overwrite its source report.")
      }
    }
    func run() async throws {
      let value = try await M5Report.from(Data(contentsOf: URL(fileURLWithPath: report)))
      try write(value, to: output)
      FileHandle.standardError.write(
        Data(
          "M5: \(value.assessment.verdict.rawValue); grounded successes \(value.assessment.counts.groundedSuccesses)/\(value.assessment.counts.attempts); real-tool target verified: false.\n"
            .utf8))
      switch value.assessment.verdict {
      case .synthetic: break
      case .belowTarget: throw ExitCode(2)
      case .incomplete, .inconclusive, .insufficientCoverage, .fixtureEvidenceOnly:
        throw ExitCode(3)
      }
    }
  }

  struct Compare: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Compare saved reports without model calls; deltas are descriptive observations.")
    @Option(help: "Baseline saved report JSON.") var baseline: String
    @Option(help: "Candidate saved report JSON.") var candidate: String
    @Option(help: "Comparison JSON output path; omit for stdout.") var output: String?
    @Flag(help: "Exit 2 for an adverse observed change in comparable live reports.")
    var failOnRegression = false
    mutating func validate() throws {
      if let output {
        let destination = URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
        guard
          ![baseline, candidate].contains(where: {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() == destination
          })
        else { throw ValidationError("Comparison output must not overwrite an input report.") }
      }
    }
    func run() throws {
      let report = try ReportComparison.compare(
        baseline: Data(contentsOf: URL(fileURLWithPath: baseline)),
        candidate: Data(contentsOf: URL(fileURLWithPath: candidate)))
      try write(report, to: output)
      FileHandle.standardError.write(
        Data(
          "Comparison: \(report.status); adverse observed change: \(report.observedRegression).\n"
            .utf8))
      if report.status == "incompatible" || report.status == "provisional" { throw ExitCode(3) }
      if failOnRegression && report.observedRegression { throw ExitCode(2) }
    }
  }

  struct ReviewRefusals: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Apply manual soft-refusal reviews to a saved report, without model calls.")
    @Option(help: "Saved schema-version-4 refusal report.") var report: String
    @Option(help: "JSON with reportID and exact-text review decisions.") var reviews: String
    @Option(help: "Output path; omit for JSON on stdout.") var output: String?
    func run() throws {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let saved = try decoder.decode(
        RefusalReport.self, from: Data(contentsOf: URL(fileURLWithPath: report)))
      let decisions = try decoder.decode(
        RefusalReviews.self, from: Data(contentsOf: URL(fileURLWithPath: reviews)))
      let updated = try saved.applying(decisions)
      try write(updated, to: output)
      try finishRefusal(updated.assessment)
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
  let timeoutSeconds: Double
  let repetitions: Int
  let validity: [ToolValidityScore]
  let validitySummary: ToolValiditySummary

  enum CodingKeys: CodingKey {
    case schemaVersion, mode, model, synthetic, operatingSystem, createdAt, suite, suiteVersion,
      context, results, validity, validitySummary, timeoutSeconds, repetitions,
      measurementProtocolVersion
  }
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(1, forKey: .measurementProtocolVersion)
    try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
    try container.encode(repetitions, forKey: .repetitions)
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
    try container.encode(validity, forKey: .validity)
    try container.encode(validitySummary, forKey: .validitySummary)
  }
}

private struct MultiReport: Encodable {
  let measurementProtocolVersion = 1
  let schemaVersion: Int
  let mode: String
  let planner: String
  let model: String
  let synthetic: Bool
  let operatingSystem: String
  let createdAt: Date
  let suite: String
  let suiteVersion: Int
  let context: SuiteLoader.Suite.Context?
  let timeoutSeconds: Double
  let repetitions: Int
  let results: [MultiStepResult]
  let attempts: Int
  let completed: Int
  let completionRate: Double?
  let m5: M5Assessment
}

private func write<T: Encodable>(_ report: T, to output: String?) throws {
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
}

private func finishRefusal(_ assessment: RefusalAssessment) throws {
  let sensitive = assessment.sensitive
  let controls = assessment.control
  let message =
    "M9: \(assessment.verdict.rawValue); known sensitive refusals \(sensitive.typedRefusals + sensitive.confirmedSoftRefusals)/\(sensitive.attempts), controls \(controls.typedRefusals + controls.confirmedSoftRefusals)/\(controls.attempts); pending reviews \(sensitive.pendingReviews + controls.pendingReviews); other errors \(sensitive.otherErrors + controls.otherErrors).\n"
  FileHandle.standardError.write(Data(message.utf8))
  switch assessment.verdict {
  case .fail: throw ExitCode(2)
  case .incomplete, .pendingReview: throw ExitCode(3)
  case .inconclusive: throw ExitCode.failure
  case .pass, .synthetic: break
  }
}

private struct ContextReport: Encodable {
  let measurementProtocolVersion = 1
  let schemaVersion: Int
  let mode: String
  let model: String
  let synthetic: Bool
  let operatingSystem: String
  let createdAt: Date
  let fixture: String
  let fixtureVersion: Int
  let repetitions: Int
  let timeoutSeconds: Double
  let budget: [String: Double]
  let outputReserveTokens: Int
  let results: [ContextLoadResult]
  let summary: ContextLoadSummary
  let groups: [String: ContextLoadSummary]
}
