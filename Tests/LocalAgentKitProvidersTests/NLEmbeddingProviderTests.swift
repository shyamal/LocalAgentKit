import LocalAgentKitCore
import NaturalLanguage
import Testing

@testable import LocalAgentKitProviders

/// `NLEmbedding` ships with the OS and needs no authorization or entitlement, unlike EventKit or
/// Foundation Models — verified in a scratch check before writing this file — so these run
/// unconditionally rather than behind a device-tests gate.
@Suite struct NLEmbeddingProviderTests {
  private let provider = NLEmbeddingProvider()

  @Test func embedsToTheKnownDimension() async throws {
    let vector = try await provider.embed(text: "The quarterly budget review is on Tuesday.")
    #expect(vector.count == 512)
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
