import LocalAgentKitCore
import NaturalLanguage

/// The default on-device embedding provider (FR-014), backed by `NLEmbedding`'s sentence
/// embedding. This is the v0.1 default per `PLANNING.md` §3; its retrieval quality against a
/// small MLX embedding model is measured later, gated at M3-04 — a full model swap before then
/// would be replacing a measured baseline with an unmeasured guess.
///
/// `NLEmbedding` is not `Sendable`; wrapping it in an actor keeps it from ever crossing an
/// isolation boundary, the pattern `EventStoreProvider` uses for EventKit.
///
/// Verified against the installed SDK (compiled and run, macOS 26.6.2): `sentenceEmbedding(for:)`
/// for `.english` returns a 512-dimension model, and `vector(for:)` is `(String) -> [Double]?`.
public actor NLEmbeddingProvider: EmbeddingProvider {
  private let embedding: NLEmbedding?
  public nonisolated let requiresNetwork = false

  /// - Parameter language: `sentenceEmbedding(for:)` returns nil for a language with no shipped
  ///   sentence-embedding model; `embed(text:)` then throws `.retrievalFailure`.
  public init(language: NLLanguage = .english) {
    self.embedding = NLEmbedding.sentenceEmbedding(for: language)
  }

  public func embed(text: String) async throws -> [Float] {
    try Task.checkCancellation()
    guard let embedding else {
      throw AgentError.retrievalFailure("no sentence embedding model for this language")
    }
    guard let vector = embedding.vector(for: text) else {
      throw AgentError.retrievalFailure("could not embed the given text")
    }
    return vector.map(Float.init)
  }
}
