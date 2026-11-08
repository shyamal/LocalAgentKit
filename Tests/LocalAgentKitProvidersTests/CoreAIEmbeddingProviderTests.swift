import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitProviders

@Suite struct CoreAIEmbeddingProviderTests {
  typealias Provider = CoreAIEmbeddingProvider

  private static let tokens = Provider.Tokens(
    inputIDs: Array(repeating: 101, count: Provider.tokenCount),
    attentionMask: Array(repeating: 1, count: Provider.tokenCount))
  private static let vector = Array(repeating: Float(0.25), count: Provider.dimensions)

  private func configuration(network: Bool = false) throws -> Provider.Configuration {
    try .init(
      modelRevision: "model-r1", tokenizerRevision: "tokenizer-r1",
      embeddingSpace: "model-r1/tokenizer-r1/fp32/mean/l2", tokenizerRequiresNetwork: network)
  }

  @Test func producesRawVectorAndDeclaresTokenizerNetworkUse() async throws {
    let config = try configuration(network: true)
    let provider = Provider(configuration: config) { text in
      #expect(text == "Same text the host receives")
      return Self.tokens
    } infer: { tokens in
      #expect(tokens.inputIDs == Self.tokens.inputIDs)
      #expect(tokens.attentionMask == Self.tokens.attentionMask)
      return Self.vector
    }
    #expect(try await provider.embed(text: "Same text the host receives") == Self.vector)
    #expect(provider.configuration.embeddingSpace == config.embeddingSpace)
    let agent = AgentConfiguration(
      model: MockModelProvider(), embedding: provider, networkPolicy: .never)
    #expect(
      throws: AgentError.invalidConfiguration(.networkRequiredButForbidden(component: "embedding"))
    ) {
      try AgentRuntime(configuration: agent, tools: StaticToolSource([]))
    }
  }

  @Test func rejectsMissingIdentity() {
    #expect(
      throws: AgentError.invalidConfiguration(
        .unsupported("Core AI embedding identifiers must be nonempty"))
    ) {
      try Provider.Configuration(
        modelRevision: "r1", tokenizerRevision: " ", embeddingSpace: "space",
        tokenizerRequiresNetwork: false)
    }
  }

  @Test func invalidTokensNeverReachInference() async throws {
    let config = try configuration()
    for tokens in [
      Provider.Tokens(inputIDs: [1], attentionMask: [1]),
      Provider.Tokens(inputIDs: Self.tokens.inputIDs, attentionMask: []),
      Provider.Tokens(
        inputIDs: Self.tokens.inputIDs, attentionMask: Self.tokens.attentionMask.map { _ in 2 }),
      Provider.Tokens(
        inputIDs: Self.tokens.inputIDs, attentionMask: Self.tokens.attentionMask.map { _ in 0 }),
      Provider.Tokens(
        inputIDs: Self.tokens.inputIDs.map { _ in -1 }, attentionMask: Self.tokens.attentionMask),
    ] {
      let provider = Provider(configuration: config) { _ in
        tokens
      } infer: { _ in
        Issue.record("Invalid tokens reached inference")
        return Self.vector
      }
      await #expect(throws: AgentError.retrievalFailure("Invalid Core AI tokenizer tensors")) {
        try await provider.embed(text: "input")
      }
    }
  }

  @Test func rejectsInvalidOutputAndMapsForeignErrors() async throws {
    let config = try configuration()
    let invalidVectors: [[Float]] = [[], Self.vector.map { _ in .nan }, Self.vector.map { _ in 0 }]
    for vector in invalidVectors {
      let provider = Provider(configuration: config) { _ in
        Self.tokens
      } infer: { _ in
        vector
      }
      await #expect(throws: AgentError.retrievalFailure("Invalid Core AI embedding vector")) {
        try await provider.embed(text: "input")
      }
    }
    let provider = Provider(configuration: config) { _ in
      Self.tokens
    } infer: { _ in
      throw CocoaError(.fileReadCorruptFile)
    }
    await #expect(throws: AgentError.retrievalFailure("Core AI embedding failed")) {
      try await provider.embed(text: "input")
    }
  }

  @Test func cancellationAfterTokenizationOrInferenceDiscardsTheResult() async throws {
    let config = try configuration()
    for cancelInTokenizer in [true, false] {
      let provider = Provider(configuration: config) { _ in
        if cancelInTokenizer { withUnsafeCurrentTask { $0?.cancel() } }
        return Self.tokens
      } infer: { _ in
        #expect(!cancelInTokenizer)
        withUnsafeCurrentTask { $0?.cancel() }
        return Self.vector
      }
      await #expect(throws: AgentError.cancelled) {
        try await Task { try await provider.embed(text: "input") }.value
      }
    }
  }
}
