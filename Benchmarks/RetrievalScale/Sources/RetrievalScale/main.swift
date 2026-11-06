import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders

struct BenchmarkError: Error { let message: String }
struct Generator {
  var state: UInt64
  mutating func vector(_ dimensions: Int) -> [Float] {
    var values: [Float] = []
    for _ in 0..<dimensions {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      values.append(Float(state >> 40) / Float(1 << 24) * 2 - 1)
    }
    let norm = values.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
    return values.map { Float(Double($0) / norm) }
  }
}
struct Report: Codable {
  let schemaVersion: Int
  let operation: String
  let store: String
  let count: Int
  let dimensions: Int
  let initializationMilliseconds: Double
  let loadMilliseconds: Double?
  let searchMilliseconds: [Double]
  let resultCount: Int
  let snapshotBytes: Int
  let fitsDefaultFileBudget: Bool
}
func milliseconds(_ duration: Duration) -> Double {
  let parts = duration.components
  return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
}

@main struct Main {
  static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 11,
      let count = Int(arguments[2]), (0...100_000).contains(count),
      let dimensions = Int(arguments[3]), (1...4096).contains(dimensions),
      let queries = Int(arguments[5]), (1...10_000).contains(queries),
      let warmups = Int(arguments[6]), (0...10_000).contains(warmups),
      let limit = Int(arguments[7]), limit > 0,
      let textCharacters = Int(arguments[8]), textCharacters >= 32,
      let seed = UInt64(arguments[9]), let maximumBytes = Int(arguments[10]), maximumBytes > 0,
      ["memory", "file"].contains(arguments[1]), ["prepare", "query"].contains(arguments[0])
    else {
      throw BenchmarkError(
        message:
          "Expected operation store count dimensions path queries warmups limit textCharacters seed maximumBytes"
      )
    }
    let operation = arguments[0]
    let kind = arguments[1]
    let url = URL(fileURLWithPath: arguments[4])
    let clock = ContinuousClock()
    let began = clock.now
    let store: any VectorStore
    let file: FileVectorStore?
    if kind == "file" {
      let value = try FileVectorStore(
        url: url, embeddingSpace: "scale-fixture-v1-\(dimensions)",
        dimensions: dimensions, maximumBytes: maximumBytes)
      store = value
      file = value
    } else {
      store = InMemoryVectorStore()
      file = nil
    }
    if kind == "memory" || operation == "prepare" {
      var generator = Generator(state: seed)
      var documents: [EmbeddedDocument] = []
      for index in 0..<count {
        let prefix = "Passage \(index): "
        let text = prefix + String(repeating: "x", count: textCharacters - prefix.count)
        let hex = String(index + 1, radix: 16)
        let idString =
          "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - hex.count) + hex
        guard let id = UUID(uuidString: idString) else {
          throw BenchmarkError(message: "Invalid fixture identity")
        }
        documents.append(
          EmbeddedDocument(
            id: id, text: text, vector: generator.vector(dimensions),
            metadata: ["title": "Scale fixture", "chunkIndex": String(index)]))
      }
      try await store.insert(documents)
      documents.removeAll()
    }
    let initialization = milliseconds(began.duration(to: clock.now))
    var loadTime: Double?
    if let file, operation == "query" {
      let loadStart = clock.now
      guard try await file.count() == count else {
        throw BenchmarkError(message: "Snapshot count mismatch")
      }
      loadTime = milliseconds(loadStart.duration(to: clock.now))
    }
    var samples: [Double] = []
    var resultCount = 0
    if operation == "query" {
      var generator = Generator(state: seed ^ 0x9e37_79b9_7f4a_7c15)
      for index in 0..<(warmups + queries) {
        let vector = generator.vector(dimensions)
        let start = clock.now
        let hits = try await store.search(vector: vector, limit: limit)
        let elapsed = milliseconds(start.duration(to: clock.now))
        guard hits.count == min(count, limit), hits.allSatisfy({ $0.score.isFinite }) else {
          throw BenchmarkError(message: "Invalid search result count or score")
        }
        resultCount += hits.count
        if index >= warmups { samples.append(elapsed) }
      }
    }
    let bytes =
      kind == "file"
      ? ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        ?? 0)
      : 0
    let report = Report(
      schemaVersion: 1, operation: operation, store: kind, count: count,
      dimensions: dimensions, initializationMilliseconds: initialization,
      loadMilliseconds: loadTime,
      searchMilliseconds: samples, resultCount: resultCount, snapshotBytes: bytes,
      fitsDefaultFileBudget: bytes <= 32 * 1024 * 1024)
    let data = try JSONEncoder().encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
  }
}
