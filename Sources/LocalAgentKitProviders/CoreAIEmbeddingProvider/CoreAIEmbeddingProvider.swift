import Foundation
import LocalAgentKitCore

#if canImport(CoreAI)
  import CoreAI
#endif

/// Opt-in embeddings for a host-supplied Core AI MiniLM-compatible model on iOS and macOS 27+.
/// The host supplies the tokenizer and keeps the model and tokenizer revisions paired.
public struct CoreAIEmbeddingProvider: EmbeddingProvider {
  /// Fixed-width Int32 token IDs and binary attention mask for a single input.
  public struct Tokens: Sendable {
    /// Token IDs, including model-specific special and padding tokens.
    public let inputIDs: [Int32]
    /// One for each attended token and zero for padding.
    public let attentionMask: [Int32]

    /// Supplies 256 entries per array, including special tokens and padding.
    public init(inputIDs: [Int32], attentionMask: [Int32]) {
      self.inputIDs = inputIDs
      self.attentionMask = attentionMask
    }
  }

  /// Explicit provenance and network declaration for one model/tokenizer pair.
  public struct Configuration: Sendable {
    /// Host-declared revision of the converted model.
    public let modelRevision: String
    /// Host-declared revision of the tokenizer and its preprocessing rules.
    public let tokenizerRevision: String
    /// Identifies the complete vector space, including preprocessing and model output semantics.
    /// Use this value for the persistent store namespace. Reindex when it changes.
    public let embeddingSpace: String
    /// Whether the host tokenizer needs a network connection.
    public let tokenizerRequiresNetwork: Bool

    /// All identifiers must be nonempty. Include model and tokenizer revisions, precision,
    /// pooling and normalization in the host's stable vector-space identifier.
    public init(
      modelRevision: String, tokenizerRevision: String, embeddingSpace: String,
      tokenizerRequiresNetwork: Bool
    ) throws {
      guard
        [modelRevision, tokenizerRevision, embeddingSpace].allSatisfy({
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
      else {
        throw AgentError.invalidConfiguration(
          .unsupported("Core AI embedding identifiers must be nonempty"))
      }
      self.modelRevision = modelRevision
      self.tokenizerRevision = tokenizerRevision
      self.embeddingSpace = embeddingSpace
      self.tokenizerRequiresNetwork = tokenizerRequiresNetwork
    }
  }

  /// The host's tokenizer, which must be safe to invoke concurrently.
  public typealias Tokenizer = @Sendable (String) async throws -> Tokens

  /// Provenance and policy of this model and tokenizer pair.
  public let configuration: Configuration
  /// Core AI uses a local model asset. The tokenizer may declare additional network use.
  public var requiresNetwork: Bool { configuration.tokenizerRequiresNetwork }
  /// Number of components returned by the supported MiniLM export.
  public static let dimensions = 384
  /// Input width of the supported MiniLM export.
  public static let tokenCount = 256

  private let tokenize: Tokenizer
  private let infer: @Sendable (Tokens) async throws -> [Float]

  init(
    configuration: Configuration, tokenize: @escaping Tokenizer,
    infer: @escaping @Sendable (Tokens) async throws -> [Float]
  ) {
    self.configuration = configuration
    self.tokenize = tokenize
    self.infer = infer
  }

  #if canImport(CoreAI)
    /// Loads a local converted asset with `main`, Int32 `input_ids` and
    /// `attention_mask` shaped [1, 256], and Float32 `embedding` shaped [1, 384].
    /// Supply a downloaded, readable file URL and keep the asset available for this provider's
    /// lifetime. Reuse the provider to share its loaded inference function.
    @available(iOS 27.0, macOS 27.0, *)
    public init(
      assetURL: URL, configuration: Configuration, tokenize: @escaping Tokenizer
    ) async throws {
      do {
        try Task.checkCancellation()
        guard assetURL.isFileURL, AIModelAsset.isValid(at: assetURL) else {
          throw AgentError.retrievalFailure("Core AI requires a valid local model asset")
        }
        let model = try await AIModel(
          contentsOf: assetURL, options: SpecializationOptions(preferredComputeUnitKind: .gpu))
        try Task.checkCancellation()
        guard let function = try model.loadFunction(named: "main") else {
          throw AgentError.retrievalFailure("Core AI model does not have a main function")
        }
        try Task.checkCancellation()
        self.init(configuration: configuration, tokenize: tokenize) { tokens in
          var outputs = try await function.run(inputs: [
            "input_ids": NDArray(scalars: tokens.inputIDs, shape: [1, Self.tokenCount]),
            "attention_mask": NDArray(scalars: tokens.attentionMask, shape: [1, Self.tokenCount]),
          ])
          try Task.checkCancellation()
          guard let value = outputs.remove("embedding"), let array = value.ndArray,
            array.shape == [1, Self.dimensions], array.scalarType == .float32,
            let elements = array.view(as: Float.self).contiguousElements
          else {
            throw AgentError.retrievalFailure("Unexpected Core AI embedding tensor")
          }
          return (0..<elements.count).map { elements[$0] }
        }
      } catch {
        throw Self.map(error, failure: "Could not load the Core AI embedding model")
      }
    }
  #endif

  /// Returns the model's raw vector. Validates tensor contents and honors cancellation.
  public func embed(text: String) async throws -> [Float] {
    do {
      try Task.checkCancellation()
      let tokens = try await tokenize(text)
      try Task.checkCancellation()
      guard tokens.inputIDs.count == Self.tokenCount,
        tokens.attentionMask.count == Self.tokenCount,
        tokens.inputIDs.allSatisfy({ $0 >= 0 }),
        tokens.attentionMask.allSatisfy({ $0 == 0 || $0 == 1 }),
        tokens.attentionMask.contains(1)
      else {
        throw AgentError.retrievalFailure("Invalid Core AI tokenizer tensors")
      }
      let vector = try await infer(tokens)
      try Task.checkCancellation()
      guard vector.count == Self.dimensions, vector.allSatisfy(\.isFinite),
        vector.contains(where: { $0 != 0 })
      else {
        throw AgentError.retrievalFailure("Invalid Core AI embedding vector")
      }
      return vector
    } catch {
      throw Self.map(error, failure: "Core AI embedding failed")
    }
  }

  private static func map(_ error: any Error, failure: String) -> AgentError {
    if Task.isCancelled || error is CancellationError { return .cancelled }
    return (error as? AgentError) ?? .retrievalFailure(failure)
  }
}
