import Foundation

/// Optional benchmark result; no concrete Core AI types enter the portable runner.
struct CoreAIProbeResult: Codable, Sendable {
  let status: String
  let failure: String?
  let comparedVectorCount: Int
  let maximumAbsoluteError: Float?
  let metadata: [String: String]
  let export: ProbeExport?
}
