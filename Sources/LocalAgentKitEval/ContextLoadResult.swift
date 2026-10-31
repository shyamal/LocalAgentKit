import LocalAgentKitRuntime

/// Actual token-counter readings. Marginal components use the assembly prefix order and are
/// not fabricated when the provider cannot count. Prefix overhead and the final question belong to instructionsToolsAndQuestion.
public struct ContextTokenMeasurements: Codable, Sendable {
  public let total: Int?
  public let prefixTokens: [String: Int]
  public let componentTokens: [String: Int]
}

public struct ContextTrim: Codable, Sendable {
  public let compactedToolOutputs: Int
  public let droppedChunks: Int
  public let summarizedMessages: Int
  public let droppedToolNames: [String]
  public let planTruncated: Bool
  init(_ report: TrimReport) {
    compactedToolOutputs = report.compactedToolOutputs
    droppedChunks = report.droppedChunks
    summarizedMessages = report.summarizedMessages
    droppedToolNames = report.droppedToolNames
    planTruncated = report.planTruncated
  }
}

/// One load-profile/probe trial. A missing source is not automatically called a hallucination.
public struct ContextLoadResult: Codable, Sendable {
  public enum ToolMode: String, Codable, Sendable, CaseIterable {
    case contextOnly = "context-only"
    case registered
  }
  public enum Outcome: String, Codable, Sendable {
    case text, unexpectedToolCall, clarification, refused, budgetExceeded, modelExceeded, timeout,
      otherError
  }
  public enum SourceStatus: String, Codable, Sendable { case retained, removed, absent, uncertain }
  public let profileID: String
  public let probeID: String
  public let repetition: Int
  public let toolMode: ToolMode
  public let outcome: Outcome
  public let sourceIncludedBeforeFit: Bool
  public let sourceAfterFit: SourceStatus?
  public let sourceAtGeneration: SourceStatus?
  public let answerMatches: Bool
  /// recalled/missed use the fixture's keyword check only when the source is demonstrably retained.
  public let recallAssessment: String
  public let response: String?
  public let error: String?
  public let beforeFit: ContextTokenMeasurements?
  public let fittedTokens: Int?
  public let fittedWindow: Int?
  public let fittedTokensAreMeasured: Bool
  public let deliveredTokens: Int?
  public let generationStarted: Bool
  public let trim: ContextTrim?
  public let elapsedSeconds: Double
}

public struct ContextLoadSummary: Codable, Sendable {
  public let attempts: Int
  public let generationAttempts: Int
  public let budgetExhaustions: Int
  public let modelExhaustions: Int
  public let otherErrors: Int
  public let refusals: Int
  public let recalled: Int
  public let missed: Int
  public let needsReview: Int
  public let exhaustionRate: Double?
  public let modelExhaustionRate: Double?
  public init(_ results: [ContextLoadResult]) {
    attempts = results.count
    generationAttempts = results.filter(\.generationStarted).count
    budgetExhaustions = results.filter { $0.outcome == .budgetExceeded }.count
    modelExhaustions = results.filter { $0.outcome == .modelExceeded }.count
    otherErrors = results.filter { $0.outcome == .otherError || $0.outcome == .timeout }.count
    refusals = results.filter { $0.outcome == .refused }.count
    recalled = results.filter { $0.recallAssessment == "recalled" }.count
    missed = results.filter { $0.recallAssessment == "missed" }.count
    needsReview =
      results.filter {
        ["needsReview", "uncertain", "answerWithoutRetainedSource"].contains($0.recallAssessment)
      }.count
    exhaustionRate =
      attempts == 0 ? nil : Double(budgetExhaustions + modelExhaustions) / Double(attempts)
    modelExhaustionRate =
      generationAttempts == 0 ? nil : Double(modelExhaustions) / Double(generationAttempts)
  }
}
