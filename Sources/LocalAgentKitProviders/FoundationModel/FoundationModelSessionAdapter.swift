import Foundation
import FoundationModels
import LocalAgentKitCore

/// Shared Foundation Models session mechanics; all concrete framework types remain in Providers.
struct FoundationModelSessionAdapter: Sendable {
  let bridge: SchemaBridge
  let maxDecodingRetries: Int
  let requireAvailable: @Sendable () throws -> Void
  let sessionFactory: @Sendable ([CapturingTool], String?, Transcript?) -> LanguageModelSession

  func tokenEntries(for request: ModelRequest) throws -> [Transcript.Entry] {
    let rendered = try TranscriptRenderer.render(request)
    let definitions = try definitions(for: request.tools)
    var entries: [Transcript.Entry] = []
    if let instructions = TranscriptRenderer.instructionsEntry(
      rendered.instructions, tools: definitions)
    {
      entries.append(instructions)
    }
    entries += rendered.entries
    entries.append(TranscriptRenderer.promptEntry(rendered.prompt))
    return entries
  }

  /// Generates using a fresh model session, handing requested tools back to the runtime.
  /// Throws mapped AgentError values; only malformed output is retried within the decoding limit.
  func generate(request: ModelRequest) async throws -> ModelResponse {
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

  /// Streams append-only text fragments from a fresh session for tool-free requests.
  /// Requests declaring tools use the ordinary capture-and-hand-back path without fragments.
  /// Malformed output is retried only before any fragment has been delivered; refusals remain terminal.
  func generate(
    request: ModelRequest, onToken: @escaping @Sendable (String) async -> Void
  ) async throws -> ModelResponse {
    guard request.tools.isEmpty else { return try await generate(request: request) }
    try requireAvailable()
    let rendered = try TranscriptRenderer.render(request)
    var attempt = 0
    while true {
      if Task.isCancelled { throw AgentError.cancelled }
      var emitted = false
      do {
        let session = makeSession(rendered, tools: [], definitions: [])
        var accumulator = StreamingTextAccumulator()
        for try await snapshot in session.streamResponse(to: rendered.prompt) {
          if Task.isCancelled { throw AgentError.cancelled }
          let delta = try accumulator.append(snapshot.content)
          if !delta.isEmpty {
            emitted = true
            await onToken(delta)
          }
        }
        if Task.isCancelled { throw AgentError.cancelled }
        return .text(accumulator.text)
      } catch {
        let mapped = await FoundationModelErrors.map(error)
        guard !emitted, mapped.isRetryable, attempt < maxDecodingRetries else { throw mapped.error }
        attempt += 1
      }
    }
  }

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
      return sessionFactory(tools, rendered.instructions.isEmpty ? nil : rendered.instructions, nil)
    }
    var entries: [Transcript.Entry] = []
    if let instructions = TranscriptRenderer.instructionsEntry(
      rendered.instructions, tools: definitions)
    {
      entries.append(instructions)
    }
    entries += rendered.entries
    return sessionFactory(tools, nil, Transcript(entries: entries))
  }

  func definitions(for tools: [ToolDescriptor]) throws -> [Transcript.ToolDefinition] {
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

}
