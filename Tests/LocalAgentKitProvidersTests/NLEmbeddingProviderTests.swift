import Foundation
import LocalAgentKitCore
import NaturalLanguage
import Testing

@testable import LocalAgentKitProviders

/// Integration tests requiring installed linguistic model assets. Like the generative model
/// tests, these are opt-in; the default unit suite must run on a host without those assets.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALAGENTKIT_DEVICE_TESTS"] == "1"))
struct NLEmbeddingProviderTests {
  private let provider = NLEmbeddingProvider()

  @Test func embedsToTheKnownDimension() async throws {
    let vector = try await provider.embed(text: "The quarterly budget review is on Tuesday.")
    #expect(vector.count == 512 || vector.count == 300)  // sentence or word fallback
    #expect(!provider.requiresNetwork)
  }

  @Test func similarSentencesAreCloserThanUnrelatedOnes() async throws {
    let a = try await provider.embed(text: "The budget meeting is scheduled for Tuesday.")
    let b = try await provider.embed(text: "Our quarterly financial review happens on Tuesday.")
    let c = try await provider.embed(text: "The zoo added a new penguin exhibit this spring.")
    #expect(cosine(a, b) > cosine(a, c))
  }

  @Test func emptyTextIsATypedErrorNotACrash() async {
    // The real model returns no vector for empty input; confirmed here rather than assumed.
    await #expect(throws: AgentError.self) { try await self.provider.embed(text: "") }
  }

  @Test func anUnsupportedLanguageThrowsATypedError() async {
    // Klingon has no shipped sentence-embedding model.
    let provider = NLEmbeddingProvider(language: NLLanguage("tlh"))
    await #expect(throws: AgentError.self) { try await provider.embed(text: "nuqneH") }
  }

  private func cosine(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    for index in a.indices {
      dot += a[index] * b[index]
      normA += a[index] * a[index]
      normB += b[index] * b[index]
    }
    return dot / (normA.squareRoot() * normB.squareRoot())
  }
}

/// The word-averaging fallback (used when the sentence-embedding asset isn't present — see
/// `NLEmbeddingProvider`'s doc comment) as a pure function of its inputs, so the averaging math
/// is verified independent of which real model assets this host happens to have.
/// Sentence embedding is present on this Mac, so `NLEmbeddingProvider.embed(text:)` itself always
/// exercises the primary path here — this suite is what actually proves the fallback is correct.
@Suite struct WordAveragingFallbackTests {
  @Test func averagesTheVectorsOfWordsThatHaveOne() {
    let vectors = ["a": [1.0, 0.0], "b": [0.0, 1.0]]
    let result = NLEmbeddingProvider.averagedVector(
      for: "a b", dimension: 2, wordVector: { vectors[$0] })
    #expect(result == [0.5, 0.5])
  }

  @Test func skipsWordsWithNoVector() {
    let vectors = ["known": [2.0, 4.0]]
    let result = NLEmbeddingProvider.averagedVector(
      for: "known unknown", dimension: 2, wordVector: { vectors[$0] })
    #expect(result == [2.0, 4.0])
  }

  @Test func nilWhenNoWordHasAVector() {
    let result = NLEmbeddingProvider.averagedVector(
      for: "nothing matches", dimension: 3, wordVector: { _ in nil })
    #expect(result == nil)
  }

  @Test func emptyTextIsNilWithoutCallingTheLookup() {
    var called = false
    let result = NLEmbeddingProvider.averagedVector(
      for: "", dimension: 3,
      wordVector: { _ in
        called = true
        return nil
      })
    #expect(result == nil)
    #expect(!called)
  }

  @Test func zeroDimensionIsNil() {
    let result = NLEmbeddingProvider.averagedVector(
      for: "word", dimension: 0, wordVector: { _ in [1.0] })
    #expect(result == nil)
  }

  @Test func aVectorOfTheWrongDimensionIsIgnored() {
    let vectors = ["good": [1.0, 1.0], "bad": [1.0, 1.0, 1.0]]
    let result = NLEmbeddingProvider.averagedVector(
      for: "good bad", dimension: 2, wordVector: { vectors[$0] })
    #expect(result == [1.0, 1.0])
  }

  @Test func punctuationIsNotTreatedAsAWord() {
    let vectors = ["budget": [1.0]]
    var lookedUp: [String] = []
    _ = NLEmbeddingProvider.averagedVector(
      for: "budget!", dimension: 1,
      wordVector: {
        lookedUp.append($0)
        return vectors[$0]
      })
    #expect(!lookedUp.contains("!"))
  }
}
