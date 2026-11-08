import CryptoKit
import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders

@available(iOS 27.0, *)
actor CoreAIEmbeddingProbe {
  private struct Fixture: Decodable {
    struct Metadata: Decodable {
      let model: String
      let revision: String
      let precision: String
      let absoluteTolerance: Float
      let assetFilesSHA256: [String: String]
    }
    struct Row: Decodable {
      let id: String
      let inputIDs: [Int32]
      let attentionMask: [Int32]
      let reference: [Float]
    }
    let schemaVersion: Int
    let corpusSHA256: String
    let metadata: Metadata
    let rows: [Row]
  }
  func run(directory: URL, corpus: ProbeCorpus, digest: String) async throws -> CoreAIProbeResult {
    var compared = 0
    var maximum: Float = 0
    var metadata: [String: String] = [
      "execution": "CoreAIEmbeddingProvider", "preferredComputeUnit": "gpu",
    ]
    do {
      try Task.checkCancellation()
      let fixture = try JSONDecoder().decode(
        Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("fixture.json")))
      let expected = Set((corpus.documents + corpus.queries).map(\.id))
      guard fixture.schemaVersion == 1, fixture.corpusSHA256 == digest,
        expected.count == corpus.documents.count + corpus.queries.count,
        fixture.rows.count == expected.count, Set(fixture.rows.map(\.id)) == expected,
        fixture.metadata.absoluteTolerance.isFinite,
        fixture.metadata.absoluteTolerance > 0, fixture.metadata.absoluteTolerance <= 1e-4,
        !fixture.metadata.assetFilesSHA256.isEmpty
      else { throw AgentError.retrievalFailure("Invalid Core AI parity fixture") }
      metadata["model"] = fixture.metadata.model
      metadata["revision"] = fixture.metadata.revision
      metadata["precision"] = fixture.metadata.precision
      metadata["absoluteTolerance"] = String(fixture.metadata.absoluteTolerance)
      let assetURL = directory.appendingPathComponent("minilm.aimodel", isDirectory: true)
      for (name, expectedHash) in fixture.metadata.assetFilesSHA256 {
        try Task.checkCancellation()
        guard !name.hasPrefix("/"), !name.contains("\\"),
          name.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw AgentError.retrievalFailure("Invalid asset-relative checksum path") }
        let data = try Data(contentsOf: assetURL.appendingPathComponent(name))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == expectedHash else {
          throw AgentError.retrievalFailure("Core AI asset checksum mismatch")
        }
      }
      let items = corpus.documents + corpus.queries
      let texts = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.text) })
      var batches: [String: CoreAIEmbeddingProvider.Tokens] = [:]
      for row in fixture.rows {
        guard let text = texts[row.id], batches[text] == nil,
          row.reference.count == CoreAIEmbeddingProvider.dimensions,
          row.reference.allSatisfy(\.isFinite)
        else { throw AgentError.retrievalFailure("Invalid or duplicate Core AI parity input") }
        batches[text] = .init(inputIDs: row.inputIDs, attentionMask: row.attentionMask)
      }
      let fixtureTokens = batches
      let configuration = try CoreAIEmbeddingProvider.Configuration(
        modelRevision: fixture.metadata.revision,
        tokenizerRevision: "pretokenized-fixture-\(digest)",
        embeddingSpace:
          "\(fixture.metadata.model)/\(fixture.metadata.revision)/\(fixture.metadata.precision)/fixture-\(digest)",
        tokenizerRequiresNetwork: false)
      let provider = try await CoreAIEmbeddingProvider(
        assetURL: assetURL, configuration: configuration
      ) {
        text in
        guard let tokens = fixtureTokens[text] else {
          throw AgentError.retrievalFailure("Text is outside the parity fixture")
        }
        return tokens
      }
      var vectors: [String: [Float]] = [:]
      for row in fixture.rows {
        try Task.checkCancellation()
        guard let text = texts[row.id] else {
          throw AgentError.retrievalFailure("Missing Core AI parity input")
        }
        let vector = try await provider.embed(text: text)
        for index in vector.indices {
          maximum = max(maximum, abs(vector[index] - row.reference[index]))
        }
        compared += 1
        vectors[row.id] = vector
      }
      guard maximum <= fixture.metadata.absoluteTolerance else {
        throw AgentError.retrievalFailure("Core AI / PyTorch numerical parity failed")
      }
      return CoreAIProbeResult(
        status: "completed", failure: nil, comparedVectorCount: compared,
        maximumAbsoluteError: maximum,
        metadata: metadata,
        export: ProbeExport(
          schemaVersion: 1, corpusSHA256: digest, provider: "minilm-coreai-fp32",
          metadata: metadata, vectors: vectors))
    } catch AgentError.cancelled {
      throw CancellationError()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      return CoreAIProbeResult(
        status: "failed", failure: String(describing: error), comparedVectorCount: compared,
        maximumAbsoluteError: compared == 0 ? nil : maximum, metadata: metadata, export: nil)
    }
  }
}
