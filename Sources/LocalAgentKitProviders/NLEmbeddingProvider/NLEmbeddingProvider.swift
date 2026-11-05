import LocalAgentKitCore
import NaturalLanguage

/// The system-asset embedding baseline (FR-014), backed by `NLEmbedding`. M3-04's measured
/// quality limits and provider policy are recorded in decision 0009. Existing APIs and demo
/// wiring remain compatible; an opt-in MiniLM/Core AI integration is tracked by M3-11.
/// The benchmark does not certify this provider for every corpus or language.
///
/// `NLEmbedding` is not `Sendable`; wrapping it in an actor keeps it from ever crossing an
/// isolation boundary, the pattern `EventStoreProvider` uses for EventKit.
///
/// **Sentence embedding first, word-averaged embedding as a fallback.** The sentence-embedding
/// model is an on-demand system asset that is not always present — observed running the demo
/// app (not reproducible from a bare SwiftPM CLI binary, which is why this needed a fallback
/// only after real-app testing found it): `NLEmbedding.sentenceEmbedding(for:)` returns nil, and
/// the framework itself logs "Unable to locate Asset for sentence embedding model for local en."
/// Word embeddings are an older, more universally bundled asset, so `embed(text:)` falls back to
/// the mean of each word's vector — coarser than a real sentence embedding (no word order or
/// context), but a real similarity signal rather than a failure. Only throws if neither model is
/// available at all.
///
/// Verified against the installed SDK (compiled and run, macOS 26.6.2): `sentenceEmbedding(for:)`
/// for `.english` returns a 512-dimension model, `wordEmbedding(for:)` returns a 300-dimension
/// one, `vector(for:)` is `(String) -> [Double]?` on both, and `NLTokenizer(unit: .word)` +
/// `enumerateTokens(in:using:)` is `(Range<String.Index>, (Range<String.Index>,
/// NLTokenizer.Attributes) -> Bool) -> Void`.
public actor NLEmbeddingProvider: EmbeddingProvider {
  private let sentenceEmbedding: NLEmbedding?
  private let wordEmbedding: NLEmbedding?
  /// False: embedding uses locally available NaturalLanguage assets.
  public nonisolated let requiresNetwork = false

  /// - Parameter language: `embed(text:)` throws `.retrievalFailure` if neither a sentence nor a
  ///   word embedding model is shipped for this language.
  public init(language: NLLanguage = .english) {
    self.sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: language)
    self.wordEmbedding = NLEmbedding.wordEmbedding(for: language)
  }

  /// Embeds text using a sentence vector, falling back to averaged available word vectors.
  /// Throws a retrieval failure if neither path yields a vector; checks cancellation on entry.
  public func embed(text: String) async throws -> [Float] {
    try Task.checkCancellation()
    if let sentenceEmbedding, let vector = sentenceEmbedding.vector(for: text) {
      return vector.map(Float.init)
    }
    if let wordEmbedding,
      let vector = Self.averagedVector(
        for: text, dimension: wordEmbedding.dimension,
        wordVector: { wordEmbedding.vector(for: $0) })
    {
      return vector
    }
    throw AgentError.retrievalFailure("no embedding model available for this language")
  }

  /// The mean of each word's vector, skipping words the model has no vector for. `nil` if no
  /// word in `text` has one. A free function of its inputs — no `NLEmbedding` needed — so the
  /// averaging itself is unit-testable independent of which real model assets happen to be
  /// present on the machine running the tests.
  static func averagedVector(
    for text: String, dimension: Int, wordVector: (String) -> [Double]?
  ) -> [Float]? {
    guard !text.isEmpty, dimension > 0 else { return nil }
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    var sum = [Double](repeating: 0, count: dimension)
    var count = 0
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      if let vector = wordVector(String(text[range])), vector.count == dimension {
        for index in vector.indices { sum[index] += vector[index] }
        count += 1
      }
      return true
    }
    guard count > 0 else { return nil }
    return sum.map { Float($0 / Double(count)) }
  }
}
