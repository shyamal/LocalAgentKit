import LocalAgentKitCore
import LocalAgentKitProviders
import NaturalLanguage

// Verified in iOS 27.2 NLEmbedding.h / NLTokenizer.h; actor isolation follows the SDK provider.
actor NativeEmbeddingPaths {
  private let sentence = NLEmbedding.sentenceEmbedding(for: .english)
  private let words = NLEmbedding.wordEmbedding(for: .english)
  private let sdk = NLEmbeddingProvider()

  func paths() -> [ProbePath] {
    let sentenceCall: ProbePath.Embed?
    if sentence != nil {
      sentenceCall = { text in try await self.sentenceVector(text) }
    } else {
      sentenceCall = nil
    }
    let wordCall: ProbePath.Embed?
    if words != nil {
      wordCall = { text in try await self.wordVector(text) }
    } else {
      wordCall = nil
    }
    return [
      ProbePath(
        name: "natural-language-sentence", metadata: details(sentence),
        embed: sentenceCall),
      ProbePath(
        name: "natural-language-word-average", metadata: details(words),
        embed: wordCall),
      ProbePath(
        name: "sdk-default", metadata: ["language": "en", "implementation": "NLEmbeddingProvider"],
        embed: { text in try await self.sdk.embed(text: text) }),
    ]
  }
  private func details(_ model: NLEmbedding?) -> [String: String] {
    guard let model else { return ["language": "en", "assetAvailable": "false"] }
    return [
      "language": "en", "assetAvailable": "true", "dimension": String(model.dimension),
      "revision": String(model.revision),
    ]
  }
  private func sentenceVector(_ text: String) throws -> [Float] {
    try Task.checkCancellation()
    guard let vector = sentence?.vector(for: text) else {
      throw AgentError.retrievalFailure("Sentence asset could not embed this text")
    }
    return vector.map(Float.init)
  }
  private func wordVector(_ text: String) throws -> [Float] {
    try Task.checkCancellation()
    guard let words else { throw AgentError.retrievalFailure("Word asset unavailable") }
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    var sum = [Double](repeating: 0, count: words.dimension)
    var count = 0
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      if let vector = words.vector(for: String(text[range])), vector.count == sum.count {
        for index in sum.indices { sum[index] += vector[index] }
        count += 1
      }
      return true
    }
    guard count > 0 else { throw AgentError.retrievalFailure("No known words in benchmark text") }
    return sum.map { Float($0 / Double(count)) }
  }
}
