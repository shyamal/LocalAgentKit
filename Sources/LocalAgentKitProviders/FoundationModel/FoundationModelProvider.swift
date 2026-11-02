import Foundation
import FoundationModels
import LocalAgentKitCore

/// Apple's on-device model as a `LocalAgentKitCore.LocalModelProvider` (FR-004).
///
/// It sits on top of Foundation Models and does not re-implement it. It does three jobs the
/// framework does not do for an agent runtime, each backed by a Phase 0 finding:
///
/// - **Hands tool calls back.** The framework runs a tool loop inside `respond()`. The tools given
///   to it here record the call and throw, so the runtime gets the call and can validate it, gate
///   it, and run it (PRD §19).
/// - **Owns the per-OS quirks** (decision 0004): optional arguments presented as required where the
///   model never fills them, no pattern guides, no reuse of a session (each request builds a fresh
///   one, which is the pattern that is safe on every OS, findings §9a), and typed errors from all
///   three generations of framework error.
/// - **Reports a real token count**, tool definitions included, so `ContextBudgeter` budgets against
///   the truth (findings §3, §10).
///
/// A guardrail refusal is thrown as `AgentError.guardrailRefusal` and is never retried here (R3).
/// Only malformed output is retried, once, on a fresh session.
public struct FoundationModelProvider: LocalModelProvider {
  private let model: SystemLanguageModel
  private let adapter: FoundationModelSessionAdapter

  /// - Parameters:
  ///   - model: The on-device system language model used for generation.
  ///   - optionalArguments: See ``OptionalArgumentPolicy``.
  ///   - maxDecodingRetries: Extra attempts when the model's output is malformed.
  public init(
    model: SystemLanguageModel = .default,
    optionalArguments: OptionalArgumentPolicy = .automatic,
    maxDecodingRetries: Int = 1
  ) {
    self.model = model
    self.adapter = FoundationModelSessionAdapter(
      bridge: SchemaBridge(optionalPolicy: optionalArguments),
      maxDecodingRetries: max(0, maxDecodingRetries),
      requireAvailable: { try Self.requireAvailable(model) },
      sessionFactory: { tools, instructions, transcript in
        if let transcript {
          return LanguageModelSession(model: model, tools: tools, transcript: transcript)
        }
        return LanguageModelSession(model: model, tools: tools, instructions: instructions)
      })
  }

  /// False: generation uses the local system model rather than a network service.
  public var requiresNetwork: Bool { false }
  /// Context size advertised by the installed system model.
  public var contextWindowTokens: Int? { model.contextSize }

  /// Starts loading the model so the first real request is faster. The model is a system-managed,
  /// shared resource: the framework offers no way to unload it (M1-PR-04).
  public func prewarm() {
    LanguageModelSession(model: model).prewarm()
  }

  /// Counts the rendered transcript and tool definitions; returns nil if rendering or counting fails.
  public func tokenCount(for request: ModelRequest) async -> Int? {
    guard let entries = try? adapter.tokenEntries(for: request) else { return nil }
    return try? await model.tokenCount(for: entries)
  }

  /// Generates with fresh sessions, validated hand-back tools and bounded malformed-output repair.
  public func generate(request: ModelRequest) async throws -> ModelResponse {
    try await adapter.generate(request: request)
  }

  /// Streams append-only fragments for tool-free requests; tool requests retain the hand-back path.
  public func generate(
    request: ModelRequest, onToken: @escaping @Sendable (String) async -> Void
  ) async throws -> ModelResponse {
    try await adapter.generate(request: request, onToken: onToken)
  }

  func modelResponse(for calls: [ToolCall], tools: [ToolDescriptor]) -> ModelResponse {
    adapter.modelResponse(for: calls, tools: tools)
  }

  private static func requireAvailable(_ model: SystemLanguageModel) throws {
    switch model.availability {
    case .available:
      return
    case .unavailable(let reason):
      let text =
        switch reason {
        case .deviceNotEligible: "this device is not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is not enabled"
        case .modelNotReady: "the model is not ready yet"
        @unknown default: "the model is unavailable"
        }
      throw AgentError.modelUnavailable(reason: text)
    }
  }
}
