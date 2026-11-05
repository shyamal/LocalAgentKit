import CryptoKit
import Foundation
import NaturalLanguage

// Standalone measurement adapter, not an SDK dependency. SDK header/API probe verified 2026-11-05.
struct Item: Decodable {
  let id: String
  let text: String
}
struct Corpus: Decodable {
  let documents: [Item]
  let queries: [Item]
}
struct Export: Encodable {
  let schemaVersion = 1
  let corpusSHA256: String
  let provider: String
  let metadata: [String: String]
  let vectors: [String: [Double]]
}
let arguments = CommandLine.arguments
guard arguments.count == 4, ["sentence", "word-average"].contains(arguments[2]) else {
  throw NSError(
    domain: "EmbeddingBenchmark", code: 1,
    userInfo: [
      NSLocalizedDescriptionKey:
        "Usage: swift export-natural-language.swift corpus.json sentence|word-average output.json"
    ])
}
let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let corpus = try JSONDecoder().decode(Corpus.self, from: data)
let mode = arguments[2]
let model =
  mode == "sentence"
  ? NLEmbedding.sentenceEmbedding(for: .english)
  : NLEmbedding.wordEmbedding(for: .english)
guard let model else {
  throw NSError(
    domain: "EmbeddingBenchmark", code: 2,
    userInfo: [
      NSLocalizedDescriptionKey:
        "Requested local embedding asset unavailable; do not silently switch benchmark paths."
    ])
}
var vectors: [String: [Double]] = [:]
let start = ContinuousClock.now
for item in corpus.documents + corpus.queries {
  guard vectors[item.id] == nil else {
    throw NSError(domain: "EmbeddingBenchmark", code: 3)
  }
  let vector: [Double]?
  if mode == "sentence" {
    vector = model.vector(for: item.text)
  } else {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = item.text
    var sum = Array(repeating: 0.0, count: model.dimension)
    var count = 0
    tokenizer.enumerateTokens(in: item.text.startIndex..<item.text.endIndex) { range, _ in
      if let word = model.vector(for: String(item.text[range])), word.count == model.dimension {
        for index in sum.indices { sum[index] += word[index] }
        count += 1
      }
      return true
    }
    vector = count > 0 ? sum.map { $0 / Double(count) } : nil
  }
  guard let vector else { throw NSError(domain: "EmbeddingBenchmark", code: 4) }
  vectors[item.id] = vector
}
let export = Export(
  corpusSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
  provider: "natural-language-\(mode)",
  metadata: [
    "language": "en", "revision": String(model.revision),
    "dimension": String(model.dimension),
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "embeddingElapsed": String(describing: start.duration(to: .now)),
  ], vectors: vectors)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
try encoder.encode(export).write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
