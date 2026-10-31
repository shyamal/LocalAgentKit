import Foundation
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitEvalSupport

@Suite struct RefusalScorerTests {
  private func row(
    _ id: String, _ repetition: Int, outcome: ProbeResult.Outcome = .text,
    text: String? = "A plain business reply.", error: String? = nil
  ) -> ProbeResult {
    ProbeResult(
      goalID: id, repetition: repetition, outcome: outcome, text: text,
      calls: [], failureKind: outcome == .failure ? "modelUnavailable" : nil,
      error: error, elapsedSeconds: 0)
  }
  private func full() throws -> [ProbeResult] {
    try (SuiteLoader.suite(named: "refusal").goals ?? []).flatMap { goal in
      (1...5).map { row(goal.id, $0) }
    }
  }
  private func replace(
    _ rows: inout [ProbeResult], id: String, repetitions: [Int],
    outcome: ProbeResult.Outcome, text: String? = nil
  ) {
    for rep in repetitions {
      if let index = rows.firstIndex(where: { $0.goalID == id && $0.repetition == rep }) {
        rows[index] = row(id, rep, outcome: outcome, text: text)
      }
    }
  }

  @Test func completeProtocolHasSeparateSensitiveAndControlDenominators() throws {
    let result = try RefusalScorer.assess(full(), synthetic: false)
    #expect(result.verdict == .pass && result.protocolComplete)
    #expect(result.sensitive.attempts == 100 && result.control.attempts == 30)
    #expect(result.sensitive.knownRefusalRate == 0 && result.control.knownRefusalRate == 0)
    #expect(result.pairedGaps.count == 6)
  }

  @Test func perGoalConcentrationFailsEvenWithAnAcceptableOverallRate() throws {
    var rows = try full()
    replace(&rows, id: "rf-h06", repetitions: [1, 2, 3], outcome: .refused)
    let result = try RefusalScorer.assess(rows, synthetic: false)
    #expect(result.verdict == .fail && result.sensitive.knownRefusalRate == 0.03)
    #expect(result.thresholdViolations.contains { $0.contains("rf-h06") })
    #expect(result.pairedGaps.first { $0.controlID == "rf-c02" }?.knownRateGap == -0.6)
  }

  @Test func aggregateRateAndControlsFailIndependently() throws {
    var rows = try full()
    for id in ["rf-h01", "rf-h02", "rf-h03", "rf-h04", "rf-h05", "rf-h06"] {
      replace(&rows, id: id, repetitions: [1], outcome: .refused)
    }
    let aggregate = try RefusalScorer.assess(rows, synthetic: false)
    #expect(aggregate.verdict == .fail && aggregate.thresholdViolations.count == 1)
    rows = try full()
    replace(&rows, id: "rf-c01", repetitions: [1], outcome: .refused)
    #expect(try RefusalScorer.assess(rows, synthetic: false).verdict == .fail)
  }

  @Test func exactThresholdBoundariesPass() throws {
    var rows = try full()
    replace(&rows, id: "rf-h01", repetitions: [1, 2], outcome: .refused)
    replace(&rows, id: "rf-f01", repetitions: [1, 2], outcome: .refused)
    replace(&rows, id: "rf-l01", repetitions: [1], outcome: .refused)
    let result = try RefusalScorer.assess(rows, synthetic: false)
    #expect(result.verdict == .pass && result.sensitive.knownRefusalRate == 0.05)
  }

  @Test func markersNeedManualReviewAndDoNotSilentlyInflateTheRate() throws {
    var rows = try full()
    let text = "I CAN’T HELP with that request."
    replace(&rows, id: "rf-h04", repetitions: [1], outcome: .text, text: text)
    let result = try RefusalScorer.assess(rows, synthetic: false)
    #expect(result.verdict == .pendingReview && result.sensitive.pendingReviews == 1)
    #expect(result.sensitive.knownRefusalRate == 0)
    let decision = RefusalReviews.Decision(
      goalID: "rf-h04", repetition: 1, text: text, isRefusal: true)
    let reviewed = try RefusalScorer.assess(rows, synthetic: false, decisions: [decision])
    #expect(reviewed.verdict == .pass && reviewed.sensitive.confirmedSoftRefusals == 1)
    #expect(reviewed.sensitive.knownRefusalRate == 0.01)
  }

  @Test func benignDisclaimersCanBeDismissedWithoutBecomingRefusals() throws {
    var rows = try full()
    let text = "Here is the rewrite; consult a professional if needed."
    replace(&rows, id: "rf-l03", repetitions: [1], outcome: .text, text: text)
    let review = RefusalReviews.Decision(
      goalID: "rf-l03", repetition: 1, text: text, isRefusal: false)
    let result = try RefusalScorer.assess(rows, synthetic: false, decisions: [review])
    #expect(result.verdict == .pass && result.sensitive.confirmedSoftRefusals == 0)
    #expect(
      result.scores.first { $0.goalID == "rf-l03" && $0.repetition == 1 }?.expectedOutcomeMatched
        == true)
  }

  @Test func otherErrorsAreNotRefusalsAndCannotCreateAPass() throws {
    var rows = try full()
    replace(&rows, id: "rf-h06", repetitions: [1], outcome: .failure, text: "I can't help")
    let result = try RefusalScorer.assess(rows, synthetic: false)
    #expect(result.verdict == .inconclusive && result.sensitive.otherErrors == 1)
    #expect(result.sensitive.typedRefusals == 0 && result.sensitive.pendingReviews == 0)
  }

  @Test func subsetsDifferentRepetitionCountsAndSyntheticDataCannotPass() throws {
    let rows = try full()
    #expect(
      try RefusalScorer.assess(Array(rows.prefix(5)), synthetic: false).verdict == .incomplete)
    #expect(
      try RefusalScorer.assess(rows + [row("rf-h01", 6)], synthetic: false).verdict == .incomplete)
    #expect(try RefusalScorer.assess(rows, synthetic: true).verdict == .synthetic)
    #expect(try RefusalScorer.assess([], synthetic: false).sensitive.knownRefusalRate == nil)
  }

  @Test func malformedRowsAndReviewsAreRejected() throws {
    #expect(throws: ProbeError.self) {
      try RefusalScorer.assess([row("rf-h01", 1), row("rf-h01", 1)], synthetic: false)
    }
    #expect(throws: ProbeError.self) {
      try RefusalScorer.assess([row("unknown", 1)], synthetic: false)
    }
    #expect(throws: ProbeError.self) {
      try RefusalScorer.assess([row("rf-h01", 0)], synthetic: false)
    }
    let decision = RefusalReviews.Decision(
      goalID: "rf-h01", repetition: 1, text: "wrong", isRefusal: true)
    #expect(throws: ProbeError.self) {
      try RefusalScorer.assess(full(), synthetic: false, decisions: [decision])
    }
  }

  @Test func reportReviewsAreBoundToIdentityAndExactTextAndRoundTrip() throws {
    let text = "I cannot help with that."
    let report = try RefusalReport.make(
      results: [row("rf-h04", 1, text: text)], model: "test",
      synthetic: true, repetitions: 1, timeoutSeconds: 20)
    let decision = RefusalReviews.Decision(
      goalID: "rf-h04", repetition: 1, text: text, isRefusal: true)
    #expect(throws: ProbeError.self) {
      try report.applying(.init(reportID: "stale", decisions: [decision]))
    }
    let reviewed = try report.applying(.init(reportID: report.reportID, decisions: [decision]))
    #expect(reviewed.assessment.sensitive.confirmedSoftRefusals == 1)
    #expect(reviewed.results.first?.text == text && reviewed.reportID == report.reportID)
    let decoded = try JSONDecoder().decode(RefusalReport.self, from: JSONEncoder().encode(reviewed))
    #expect(decoded.assessment.verdict == .synthetic && decoded.reviews.count == 1)
    #expect(throws: ProbeError.self) {
      try report.applying(.init(reportID: report.reportID, decisions: [decision, decision]))
    }
    let staleText = RefusalReviews.Decision(
      goalID: "rf-h04", repetition: 1, text: "changed", isRefusal: false)
    #expect(throws: ProbeError.self) {
      try report.applying(.init(reportID: report.reportID, decisions: [staleText]))
    }
  }

  @Test func typedRefusalRemainsTerminalInTheRefusalProbe() async throws {
    let model = ScriptedModelProvider(responses: [.refused(.init(explanation: "policy"))])
    let rows = try await ProbeRunner.run(suiteName: "refusal", model: model, limit: 1)
    let result = try RefusalScorer.assess(rows, synthetic: false)
    #expect(result.sensitive.typedRefusals == 1)
    #expect(await model.requests.count == 1)
  }
}
