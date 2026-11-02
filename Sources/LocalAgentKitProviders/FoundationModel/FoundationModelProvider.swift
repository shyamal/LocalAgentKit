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
  private let bridge: SchemaBridge
  private let maxDecodingRetries: Int

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
    self.bridge = SchemaBridge(optionalPolicy: optionalArguments)
    self.maxDecodingRetries = max(0, maxDecodingRetries)
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
    guard let rendered = try? TranscriptRenderer.render(request),
      let definitions = try? definitions(for: request.tools)
    else { return nil }
    var entries: [Transcript.Entry] = []
    if let instructions = TranscriptRenderer.instructionsEntry(
      rendered.instructions, tools: definitions)
    {
      entries.append(instructions)
    }
    entries += rendered.entries
    entries.append(TranscriptRenderer.promptEntry(rendered.prompt))
    return try? await model.tokenCount(for: entries)
  }

  /// Generates using a fresh system-model session, handing requested tools back to the runtime.
  /// Throws mapped AgentError values; only malformed output is retried within the decoding limit.
  public func generate(request: ModelRequest) async throws -> ModelResponse {
    try requireAvailable()
    let rendered = try TranscriptRenderer.render(request)
    var attempt = 0
    while true {
      if Task.isCancelled { throw AgentError.cancelled }
      do {
        return try await respond(to: rendered, request: request)
      } catch {
        let mapped = await FoundationModelErrors.map(error)
        guard mapped.isRetryable, attempt < maxDecodingRetries else { throw mapped.error }
        attempt += 1
      }
    }
  }

  // MARK: One attempt

  private func respond(to rendered: RenderedRequest, request: ModelRequest) async throws
    -> ModelResponse
  {
    let recorder = CallRecorder()
    let tools = try request.tools.map {
      CapturingTool($0, schema: try bridge.generationSchema(for: $0), recorder: recorder)
    }
    // A fresh session per request, never reused: reusing one after an abandoned request crashed
    // the process on macOS 26 (findings §9a), and the runtime owns the conversation anyway.
    let session = try makeSession(
      rendered, tools: tools, definitions: definitions(for: request.tools))

    do {
      let response = try await session.respond(to: rendered.prompt)
      if Task.isCancelled { throw AgentError.cancelled }
      let calls = await recorder.recorded
      return calls.isEmpty
        ? .text(response.content) : modelResponse(for: calls, tools: request.tools)
    } catch let error as LanguageModelSession.ToolCallError where error.underlyingError is HandBack
    {
      if Task.isCancelled { throw AgentError.cancelled }
      return modelResponse(for: await recorder.recorded, tools: request.tools)
    }
  }

  private func makeSession(
    _ rendered: RenderedRequest, tools: [CapturingTool], definitions: [Transcript.ToolDefinition]
  ) -> LanguageModelSession {
    if rendered.entries.isEmpty {
      return LanguageModelSession(
        model: model, tools: tools,
        instructions: rendered.instructions.isEmpty ? nil : rendered.instructions)
    }
    var entries: [Transcript.Entry] = []
    if let instructions = TranscriptRenderer.instructionsEntry(
      rendered.instructions, tools: definitions)
    {
      entries.append(instructions)
    }
    entries += rendered.entries
    return LanguageModelSession(
      model: model, tools: tools, transcript: Transcript(entries: entries))
  }

  private func definitions(for tools: [ToolDescriptor]) throws -> [Transcript.ToolDefinition] {
    try tools.map {
      Transcript.ToolDefinition(
        name: $0.name, description: $0.description, parameters: try bridge.generationSchema(for: $0)
      )
    }
  }

  /// One call, or several, as the model asked. An optional argument that was presented as required
  /// and came back empty is dropped, so the runtime sees what the tool actually declared.
  func modelResponse(for calls: [ToolCall], tools: [ToolDescriptor]) -> ModelResponse {
    let cleaned = calls.map { call -> ToolCall in
      guard let descriptor = tools.first(where: { $0.name == call.name }),
        bridge.optionalPolicy.presentsOptionalAsRequired
      else { return call }
      var call = call
      for (name, value) in call.arguments.values where !descriptor.schema.required.contains(name) {
        if value == .null || value == .string("") { call.arguments.values[name] = nil }
      }
      return call
    }
    return cleaned.count == 1 ? .toolCall(cleaned[0]) : .multipleToolCalls(cleaned)
  }

  private func requireAvailable() throws {
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
