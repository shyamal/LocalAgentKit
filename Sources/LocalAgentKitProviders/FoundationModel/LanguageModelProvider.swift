import FoundationModels
import LocalAgentKitCore

/// Adapts an OS 27 Foundation Models LanguageModel conformance to the framework-neutral runtime.
///
/// Copies share one model holder under ARC; reuse the same provider across agents. Backend loading,
/// executor caching and resource eviction remain the model/executor's responsibility: Apple's
/// protocol has no generic unload or token-count API. Construction does not create a session.
@available(macOS 27, iOS 27, *)
public struct LanguageModelProvider<Model: LanguageModel>: LocalModelProvider {
  /// Whether the model or supplied token counter requires network access; declared explicitly.
  public let requiresNetwork: Bool
  /// Caller-supplied model window, or nil to use the runtime's fallback allowance.
  public let contextWindowTokens: Int?
  private let storage: SharedLanguageModelStorage<Model>
  private let counter: (@Sendable ([Transcript.Entry]) async -> Int?)?
  private let adapter: FoundationModelSessionAdapter
  private let enableStreaming: Bool

  /// - Parameters:
  ///   - model: The app-owned model conformance; the adapter does not create weights or executors.
  ///   - requiresNetwork: True for any network-backed model or token counter; `.never` rejects it.
  ///   - contextWindowTokens: Known positive window size, or nil when unknown.
  ///   - tokenCounter: Optional backend counter receiving rendered transcript entries including tools.
  ///     Nil uses the runtime's estimated counts. Return nil if an exact count is unavailable.
  ///   - optionalArguments: Optional-field presentation policy; defaults to the OS 27 declaration.
  ///   - maxDecodingRetries: Bounded retries for malformed output; no retries after streamed text.
  ///   - enableStreaming: Opt in only for backends producing append-only text snapshots.
  ///     Defaults to non-streaming because generic executors may replace earlier text segments.
  /// - Throws: A typed invalid-configuration error for a non-positive context window.
  public init(
    model: Model, requiresNetwork: Bool, contextWindowTokens: Int? = nil,
    tokenCounter: (@Sendable ([Transcript.Entry]) async -> Int?)? = nil,
    optionalArguments: OptionalArgumentPolicy = .asDeclared, maxDecodingRetries: Int = 1,
    enableStreaming: Bool = false
  ) throws {
    if let contextWindowTokens, contextWindowTokens <= 0 {
      throw AgentError.invalidConfiguration(.invalidLimit("contextWindowTokens must be positive"))
    }
    let storage = SharedLanguageModelStorage(model: model)
    self.storage = storage
    self.requiresNetwork = requiresNetwork
    self.contextWindowTokens = contextWindowTokens
    self.counter = tokenCounter
    self.enableStreaming = enableStreaming
    self.adapter = FoundationModelSessionAdapter(
      bridge: SchemaBridge(optionalPolicy: optionalArguments),
      maxDecodingRetries: max(0, maxDecodingRetries), requireAvailable: {},
      sessionFactory: { tools, instructions, transcript in
        if let transcript {
          return LanguageModelSession(model: storage.model, tools: tools, transcript: transcript)
        }
        return LanguageModelSession(model: storage.model, tools: tools, instructions: instructions)
      })
  }

  /// Requests backend prewarming through a fresh session; availability failures surface on generation.
  public func prewarm() { LanguageModelSession(model: storage.model).prewarm() }

  /// Counts the actual rendered entries using the supplied backend counter, or returns nil.
  public func tokenCount(for request: ModelRequest) async -> Int? {
    guard let counter, let entries = try? adapter.tokenEntries(for: request) else { return nil }
    return await counter(entries)
  }

  /// Generates through a fresh session, handing tool calls back for runtime validation and permission.
  public func generate(request: ModelRequest) async throws -> ModelResponse {
    try validateCapabilities(for: request)
    return try await adapter.generate(request: request)
  }

  /// Streams tool-free text when enabled; otherwise generates a final response without fragments.
  public func generate(
    request: ModelRequest, onToken: @escaping @Sendable (String) async -> Void
  ) async throws -> ModelResponse {
    try validateCapabilities(for: request)
    guard enableStreaming else { return try await adapter.generate(request: request) }
    return try await adapter.generate(request: request, onToken: onToken)
  }

  private func validateCapabilities(for request: ModelRequest) throws {
    if !request.tools.isEmpty, !storage.model.capabilities.contains(.toolCalling) {
      throw AgentError.modelUnavailable(reason: "the model does not advertise tool-calling support")
    }
  }
}

@available(macOS 27, iOS 27, *)
private final class SharedLanguageModelStorage<Model: LanguageModel>: Sendable {
  let model: Model
  init(model: Model) { self.model = model }
}
