import Foundation

/// A single OS/model measurement with reviewable raw responses and the M9 assessment.
public struct RefusalReport: Codable, Sendable {
  public let measurementProtocolVersion: Int?
  public let schemaVersion: Int
  public let reportID: String
  public let mode: String
  public let operatingSystem: String
  public let createdAt: Date
  public let model: String
  public let synthetic: Bool
  public let suite: String
  public let suiteVersion: Int
  public let context: SuiteLoader.Suite.Context?
  public let repetitions: Int
  public let timeoutSeconds: Double
  public let results: [ProbeResult]
  public private(set) var reviews: [RefusalReviews.Decision]
  public private(set) var assessment: RefusalAssessment

  public static func make(
    results: [ProbeResult], model: String, synthetic: Bool,
    repetitions: Int, timeoutSeconds: Double
  ) throws -> RefusalReport {
    let suite = try SuiteLoader.suite(named: "refusal")
    return RefusalReport(
      measurementProtocolVersion: 1, schemaVersion: 4, reportID: UUID().uuidString,
      mode: "refusal-probe",
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, createdAt: Date(),
      model: model, synthetic: synthetic, suite: suite.name, suiteVersion: suite.version,
      context: suite.context, repetitions: repetitions, timeoutSeconds: timeoutSeconds,
      results: results,
      reviews: [], assessment: try RefusalScorer.assess(results, synthetic: synthetic))
  }

  /// Applies explicit human decisions without rerunning the model. New decisions replace earlier
  /// decisions for the same response; all decisions are checked against the raw response text.
  public func applying(_ input: RefusalReviews) throws -> RefusalReport {
    let metadata = try SuiteLoader.suite(named: "refusal")
    guard schemaVersion == 4, input.reportID == reportID, suite == metadata.name,
      suiteVersion == metadata.version, context == metadata.context
    else {
      throw ProbeError.invalidOptions("Review/report identity or suite protocol does not match.")
    }
    var merged: [String: RefusalReviews.Decision] = [:]
    for review in reviews { merged[RefusalScorer.key(review.goalID, review.repetition)] = review }
    var seen: Set<String> = []
    for review in input.decisions {
      let key = RefusalScorer.key(review.goalID, review.repetition)
      guard seen.insert(key).inserted else {
        throw ProbeError.invalidOptions("Duplicate review for \(key).")
      }
      merged[key] = review
    }
    var report = self
    report.reviews = merged.keys.sorted().compactMap { merged[$0] }
    report.assessment = try RefusalScorer.assess(
      results, synthetic: synthetic, decisions: report.reviews)
    return report
  }
}
