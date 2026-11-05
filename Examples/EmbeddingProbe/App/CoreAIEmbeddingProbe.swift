import CoreAI
import CryptoKit
import Foundation
import LocalAgentKitCore

// API names/signatures verified against the installed iOS 27.2 interfaces before compilation.
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
    var metadata: [String: String] = ["execution": "CoreAIRuntime", "preferredComputeUnit": "gpu"]
    do {
      try Task.checkCancellation()
      let fixture = try JSONDecoder().decode(
        Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("fixture.json")))
      let expected = Set((corpus.documents + corpus.queries).map(\.id))
      guard fixture.schemaVersion == 1, fixture.corpusSHA256 == digest,
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
      guard AIModelAsset.isValid(at: assetURL) else {
        throw AgentError.retrievalFailure("Converted artifact is not a valid Core AI asset")
      }
      try Task.checkCancellation()
      let model = try await AIModel(
        contentsOf: assetURL, options: SpecializationOptions(preferredComputeUnitKind: .gpu))
      try Task.checkCancellation()
      guard let function = try model.loadFunction(named: "main") else {
        throw AgentError.retrievalFailure("Converted model lacks main inference function")
      }
      var vectors: [String: [Float]] = [:]
      for row in fixture.rows {
        try Task.checkCancellation()
        guard row.inputIDs.count == 256, row.attentionMask.count == 256,
          row.inputIDs.allSatisfy({ $0 >= 0 }),
          row.attentionMask.allSatisfy({ $0 == 0 || $0 == 1 }),
          row.reference.count == 384, row.reference.allSatisfy(\.isFinite)
        else { throw AgentError.retrievalFailure("Invalid fixed-shape Core AI tensor fixture") }
        var outputs = try await function.run(inputs: [
          "input_ids": NDArray(scalars: row.inputIDs, shape: [1, 256]),
          "attention_mask": NDArray(scalars: row.attentionMask, shape: [1, 256]),
        ])
        try Task.checkCancellation()
        guard let value = outputs.remove("embedding"), let array = value.ndArray,
          array.shape == [1, 384], array.scalarType == .float32
        else { throw AgentError.retrievalFailure("Unexpected Core AI output shape or scalar type") }
        let vector = Self.readVector(array)
        guard vector.count == 384, vector.allSatisfy(\.isFinite) else {
          throw AgentError.retrievalFailure("Invalid Core AI embedding")
        }
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
    } catch is CancellationError { throw CancellationError() } catch {
      try Task.checkCancellation()
      return CoreAIProbeResult(
        status: "failed", failure: String(describing: error), comparedVectorCount: compared,
        maximumAbsoluteError: compared == 0 ? nil : maximum, metadata: metadata, export: nil)
    }
  }
  private static func readVector(_ array: NDArray) -> [Float] {
    let view = array.view(as: Float.self)
    guard let elements = view.contiguousElements else { return [] }
    var vector: [Float] = []
    for index in 0..<elements.count { vector.append(elements[index]) }
    return vector
  }
}
