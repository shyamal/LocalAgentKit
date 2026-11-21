import Foundation
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitEvalSupport

@Suite struct RetainedPlannerEvidenceTests {
  @Test(arguments: ["2026-11-21-planner-macos", "2026-11-21-planner-ios"])
  func reportsMatchIndependentRawResultReplay(_ folder: String) async throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("docs/eval-results").appendingPathComponent(folder)
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    for file in ["model-driven.json", "state-machine.json"] {
      let data = try Data(contentsOf: root.appendingPathComponent(file))
      let replay = try await M5Report.from(data)
      let saved = try decoder.decode(JSONValue.self, from: data)
      guard case .object(let fields) = saved else {
        Issue.record("Expected a report object")
        return
      }
      #expect(
        try decoder.decode(JSONValue.self, from: encoder.encode(replay.assessment)) == fields["m5"])
      #expect(!replay.assessment.realToolTargetVerified)
    }
    struct Single: Decodable { let results: [ProbeResult] }
    let data = try Data(contentsOf: root.appendingPathComponent("single-tool.json"))
    let rows = try decoder.decode(Single.self, from: data).results
    let scorer = try ToolValidityScorer(tools: SuiteLoader.tools())
    let scores = try scorer.score(rows)
    guard case .object(let fields) = try decoder.decode(JSONValue.self, from: data) else {
      Issue.record("Expected single-tool report object")
      return
    }
    #expect(try decoder.decode(JSONValue.self, from: encoder.encode(scores)) == fields["validity"])
    #expect(
      try decoder.decode(JSONValue.self, from: encoder.encode(scorer.summary(scores)))
        == fields["validitySummary"])
    #expect(rows.count == 100)
  }
}
