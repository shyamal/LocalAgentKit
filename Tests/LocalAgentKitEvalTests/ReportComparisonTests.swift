import Foundation
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitEvalSupport

private func contextReport(
  outcome: String = "text", matched: Bool = true,
  source: String = "retained", synthetic: Bool = false
) -> [String: Any] {
  [
    "schemaVersion": 5, "measurementProtocolVersion": 1, "mode": "sdk-budgeted-context",
    "model": "foundation", "synthetic": synthetic, "operatingSystem": "OS A",
    "createdAt": "2026-10-24T00:00:00Z", "fixture": "fixture", "fixtureVersion": 1,
    "budget": ["systemAndTools": 0.3, "conversation": 0.4, "rag": 0.2, "plan": 0.1],
    "outputReserveTokens": 512, "repetitions": 1,
    "timeoutSeconds": 20,
    "results": [
      [
        "profileID": "heavy", "probeID": "probe", "toolMode": "registered",
        "repetition": 1, "outcome": outcome, "generationStarted": true,
        "sourceAtGeneration": source, "answerMatches": matched, "elapsedSeconds": 1.0,
      ]
    ],
    "summary": ["modelExhaustions": 999],
  ]
}
private func reportData(_ value: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
private func comparison(_ a: [String: Any], _ b: [String: Any]) throws -> ReportComparison {
  try ReportComparison.compare(baseline: reportData(a), candidate: reportData(b))
}

@Suite struct ReportComparisonTests {
  @Test func countersAreRebuiltAndAdverseChangesUsePercentagePoints() throws {
    let old = contextReport()
    let new = contextReport(outcome: "modelExceeded")
    let report = try comparison(old, new)
    #expect(report.status == "comparable" && report.observedRegression)
    let change = try #require(report.changes.first { $0.metric == "all/exhaustion" })
    #expect(change.baseline.numerator == 0 && change.candidate.numerator == 1)
    #expect(change.delta == 100 && change.adverse)
    #expect(change.unit == "percentagePoints")
    #expect(try comparison(new, old).changes.first { $0.metric == "all/exhaustion" }?.delta == -100)
  }

  @Test func zeroConditionalDenominatorsRemainUnknownAndEncodeWithoutNaN() throws {
    let report = try comparison(
      contextReport(source: "removed"), contextReport(outcome: "unexpectedToolCall"))
    let recall = try #require(report.changes.first { $0.metric == "all/retainedSourceRecall" })
    #expect(recall.baseline.denominator == 0 && recall.baseline.value == nil)
    #expect(recall.candidate.denominator == 0 && recall.delta == nil && !recall.adverse)
    _ = try JSONEncoder().encode(report)
  }

  @Test func unchangedReportsHaveZeroDeltasAndOSChangesAreExplicit() throws {
    var new = contextReport()
    new["operatingSystem"] = "OS B"
    let report = try comparison(contextReport(), new)
    #expect(report.status == "comparable" && !report.observedRegression)
    #expect(report.changes.allSatisfy { $0.delta == 0 })
    #expect(report.warnings.contains { $0.contains("OS versions differ") })
  }

  @Test func rowOrderDoesNotMatterAndLatencyUsesSeconds() throws {
    var old = contextReport()
    var first = try #require((old["results"] as? [[String: Any]])?.first)
    var second = first
    second["probeID"] = "second"
    second["elapsedSeconds"] = 3.0
    old["results"] = [first, second]
    var new = old
    first["elapsedSeconds"] = 3.0
    new["results"] = [second, first]
    let report = try comparison(old, new)
    #expect(report.status == "comparable")
    let change = try #require(report.changes.first { $0.metric == "all/meanLatency" })
    #expect(change.baseline.value == 2 && change.candidate.value == 3)
    #expect(change.baseline.denominator == 2 && change.delta == 1 && change.unit == "seconds")
  }

  @Test func mismatchedProtocolsProduceNoDeltas() throws {
    let original = contextReport()
    for (field, value): (String, Any) in [
      ("timeoutSeconds", 21),
      ("budget", ["systemAndTools": 0.3, "conversation": 0.5, "rag": 0.2, "plan": 0.1]),
      ("fixtureVersion", 2), ("model", "other"), ("repetitions", 2),
      ("synthetic", true), ("outputReserveTokens", 256),
    ] {
      var new = original
      new[field] = value
      let report = try comparison(original, new)
      #expect(report.status == "incompatible" && report.changes.isEmpty)
      #expect(!report.observedRegression)
    }
    var new = original
    var rows = try #require(new["results"] as? [[String: Any]])
    rows[0]["probeID"] = "other"
    new["results"] = rows
    #expect(try comparison(original, new).status == "incompatible")
  }

  @Test func missingLegacyMetadataIsProvisionalAndMocksCannotFlagRegression() throws {
    var old = contextReport()
    old.removeValue(forKey: "measurementProtocolVersion")
    var new = contextReport(outcome: "modelExceeded")
    new.removeValue(forKey: "measurementProtocolVersion")
    let legacy = try comparison(old, new)
    #expect(legacy.status == "provisional" && !legacy.observedRegression)
    #expect(!legacy.changes.isEmpty)
    let mock = try comparison(
      contextReport(synthetic: true), contextReport(outcome: "modelExceeded", synthetic: true))
    #expect(mock.status == "synthetic" && !mock.observedRegression)
  }

  @Test func malformedReportsAreRejectedInsteadOfBecomingZeroRates() throws {
    for field in ["schemaVersion", "fixture", "results"] {
      var invalid = contextReport()
      invalid.removeValue(forKey: field)
      #expect(throws: (any Error).self) { try comparison(invalid, contextReport()) }
    }
    var duplicate = contextReport()
    let rows = try #require(duplicate["results"] as? [[String: Any]])
    duplicate["results"] = rows + rows
    #expect(throws: ProbeError.self) { try comparison(duplicate, contextReport()) }
    for (field, value): (String, Any) in [
      ("schemaVersion", 99), ("measurementProtocolVersion", 2), ("mode", "wrong"),
      ("createdAt", "bad"),
    ] {
      var invalid = contextReport()
      invalid[field] = value
      #expect(throws: ProbeError.self) { try comparison(invalid, contextReport()) }
    }
  }

  @Test func singleToolUsesEmittedCallAndAttemptDenominators() throws {
    var report: [String: Any] = [
      "schemaVersion": 2, "measurementProtocolVersion": 1, "mode": "single-call-probe",
      "model": "foundation", "synthetic": false, "operatingSystem": "OS A",
      "createdAt": "2026-10-24T00:00:00Z", "suite": "single-tool", "suiteVersion": 1,
      "context": ["timeZone": "UTC"], "repetitions": 1, "timeoutSeconds": 20,
      "results": [
        [
          "goalID": "st-01", "repetition": 1, "calls": [["name": "calculate"]],
          "outcome": "toolCalls", "elapsedSeconds": 1,
        ]
      ],
      "validity": [
        [
          "goalID": "st-01", "repetition": 1,
          "calls": [["name": "calculate", "valid": true, "violations": []]],
        ]
      ],
    ]
    let before = report
    report["validity"] = [
      [
        "goalID": "st-01", "repetition": 1,
        "calls": [["name": "calculate", "valid": false, "violations": ["missing argument"]]],
      ]
    ]
    let result = try comparison(before, report)
    #expect(result.changes.first { $0.metric == "all/validFirstCall" }?.delta == -100)
    #expect(
      result.changes.first { $0.metric == "all/validEmittedCall" }?.candidate.denominator == 1)
    #expect(result.observedRegression)
    report["validity"] = []
    #expect(throws: ProbeError.self) { try comparison(before, report) }
  }

  @Test func multiStepComparesCompletionAndKeepsErrorsSeparate() throws {
    var report: [String: Any] = [
      "schemaVersion": 3, "measurementProtocolVersion": 1, "mode": "agent-run",
      "planner": "stateMachine-open", "model": "foundation", "synthetic": false,
      "operatingSystem": "OS A", "createdAt": "2026-10-24T00:00:00Z",
      "suite": "multi-step", "suiteVersion": 1, "context": ["timeZone": "UTC"],
      "repetitions": 1, "timeoutSeconds": 20,
      "results": [
        [
          "goalID": "ms-01", "repetition": 1,
          "score": [
            "completed": true, "matchedCallIndices": ["step": 0], "stepsExpected": 1,
            "stepsMatched": 1,
          ], "calls": [["completed": true]], "stopReason": "answer",
          "elapsedSeconds": 1,
        ]
      ],
    ]
    let before = report
    report["results"] = [
      [
        "goalID": "ms-01", "repetition": 1,
        "score": [
          "completed": false, "matchedCallIndices": [:], "stepsExpected": 1, "stepsMatched": 0,
        ], "calls": [["completed": true]], "stopReason": "loop",
        "elapsedSeconds": 1,
      ]
    ]
    let result = try comparison(before, report)
    #expect(result.changes.first { $0.metric == "all/completed" }?.delta == -100)
    #expect(result.changes.first { $0.metric == "all/groundedToolSuccess" }?.delta == -100)
    #expect(result.changes.first { $0.metric == "all/fixtureExecution" }?.delta == 0)
    #expect(result.changes.first { $0.metric == "all/requiredStepMatch" }?.delta == -100)
    #expect(result.changes.first { $0.metric == "all/loops" }?.delta == 100)
    #expect(result.changes.first { $0.metric == "all/failures" }?.delta == 0)
  }

  @Test func refusalReviewsAreRevalidatedAndPendingDecisionsAreProvisional() throws {
    let suite = try SuiteLoader.suite(named: "refusal")
    let goal = try #require(suite.goals?.first)
    let marker = try #require(suite.scoring?.softRefusalMarkers?.first)
    let row = ProbeResult(
      goalID: goal.id, repetition: 1, outcome: .text, text: marker,
      calls: [], failureKind: nil, error: nil, elapsedSeconds: 1)
    let report = try RefusalReport.make(
      results: [row], model: "foundation", synthetic: false, repetitions: 1, timeoutSeconds: 20)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(report)
    let compared = try ReportComparison.compare(baseline: data, candidate: data)
    #expect(compared.status == "provisional" && !compared.observedRegression)
    #expect(compared.changes.first { $0.metric == "all/pendingReviews" }?.baseline.numerator == 1)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var assessment = try #require(object["assessment"] as? [String: Any])
    assessment["verdict"] = "pass"
    object["assessment"] = assessment
    #expect(throws: ProbeError.self) {
      try ReportComparison.compare(baseline: data, candidate: reportData(object))
    }
  }
}
