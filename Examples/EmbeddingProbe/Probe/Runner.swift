import Foundation
import LocalAgentKitCore

struct ProbeCorpus: Decodable, Sendable {
  struct Item: Decodable, Sendable {
    let id: String
    let text: String
  }
  let documents: [Item]
  let queries: [Item]
}
struct ProbePath: Sendable {
  typealias Embed = @Sendable (String) async throws -> [Float]
  let name: String
  let metadata: [String: String]
  let embed: Embed?
}
struct ProbeExport: Codable, Sendable {
  let schemaVersion: Int
  let corpusSHA256: String
  let provider: String
  let metadata: [String: String]
  let vectors: [String: [Float]]
}
struct ProbeResult: Codable, Sendable {
  enum Status: String, Codable, Sendable { case completed, unavailable, failed }
  let path: String
  let status: Status
  let metadata: [String: String]
  let elapsedMilliseconds: Double
  let failure: String?
  let export: ProbeExport?
}
struct ProbeReport: Codable, Sendable {
  let schemaVersion: Int
  let runID: UUID
  let corpusSHA256: String
  var metadata: [String: String]
  let results: [ProbeResult]
}
enum ProbeRunner {
  static func run(
    corpus: ProbeCorpus, digest: String, paths: [ProbePath],
    metadata: [String: String], runID: UUID = UUID()
  ) async throws -> ProbeReport {
    let items = corpus.documents + corpus.queries
    guard !corpus.documents.isEmpty, !corpus.queries.isEmpty,
      items.allSatisfy({ !$0.id.isEmpty && !$0.text.isEmpty }),
      Set(items.map(\.id)).count == items.count,
      Set(paths.map(\.name)).count == paths.count
    else { throw AgentError.retrievalFailure("Invalid benchmark corpus or duplicate paths") }
    var results: [ProbeResult] = []
    for path in paths {
      try Task.checkCancellation()
      guard let embed = path.embed else {
        results.append(
          ProbeResult(
            path: path.name, status: .unavailable, metadata: path.metadata,
            elapsedMilliseconds: 0, failure: "Requested local asset unavailable", export: nil))
        continue
      }
      let start = ContinuousClock.now
      do {
        var vectors: [String: [Float]] = [:]
        var dimension: Int?
        for item in items {
          try Task.checkCancellation()
          let vector = try await embed(item.text)
          try Task.checkCancellation()
          guard !vector.isEmpty, vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }),
            dimension == nil || dimension == vector.count
          else { throw AgentError.retrievalFailure("Invalid or incompatible benchmark vector") }
          dimension = vector.count
          vectors[item.id] = vector
        }
        results.append(
          ProbeResult(
            path: path.name, status: .completed, metadata: path.metadata,
            elapsedMilliseconds: milliseconds(start.duration(to: .now)), failure: nil,
            export: ProbeExport(
              schemaVersion: 1, corpusSHA256: digest, provider: path.name,
              metadata: metadata.merging(path.metadata) { _, pathValue in pathValue },
              vectors: vectors)))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
        if (error as? AgentError) == .cancelled { throw AgentError.cancelled }
        results.append(
          ProbeResult(
            path: path.name, status: .failed, metadata: path.metadata,
            elapsedMilliseconds: milliseconds(start.duration(to: .now)),
            failure: String(describing: error), export: nil))
      }
    }
    try Task.checkCancellation()
    return ProbeReport(
      schemaVersion: 1, runID: runID, corpusSHA256: digest, metadata: metadata, results: results)
  }
  private static func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
  }
}
