import Foundation
import FoundationModels
import LocalAgentKitCore

/// A ``ModelRequest`` in the framework's terms: what to seed a fresh session with, and what to
/// ask it.
struct RenderedRequest {
  var instructions: String
  var entries: [Transcript.Entry]
  /// The message the session is asked to respond to.
  var prompt: String
}

/// Translates messages into a `Transcript`, keeping it valid.
///
/// Two rules come from Phase 0. A tool output must carry the id of the call it answers, or iOS 27
/// rejects the whole transcript with an untyped error that does not say why (findings §10a). And a
/// call is never left without its output. So an output with no matching call, or a call whose
/// outputs are missing, is rendered as plain text instead of being passed through.
enum TranscriptRenderer {
  static func render(_ request: ModelRequest) throws -> RenderedRequest {
    let leading = request.messages.prefix { $0.role == .system }
    var conversation = Array(request.messages.dropFirst(leading.count))

    // What the session is asked to respond to.
    let prompt: String
    switch conversation.last?.role {
    case .user?:
      prompt = conversation.removeLast().content
    case .tool?:
      // A result awaiting the model's next turn. Fold the trailing calls and outputs into the
      // prompt: there is no way to ask a session to "continue" after an output.
      var results: [String] = []
      while let last = conversation.last, last.role == .tool {
        results.insert("Result: " + last.content, at: 0)
        conversation.removeLast()
      }
      if let last = conversation.last, last.role == .assistant, !last.toolCalls.isEmpty {
        conversation.removeLast()
      }
      prompt = results.joined(separator: "\n")
    case .assistant?, .system?:
      throw AgentError.modelUnavailable(
        reason: "the request ends with a \(conversation.last!.role) message")
    case nil:
      throw AgentError.modelUnavailable(reason: "the request has nothing to respond to")
    }

    return RenderedRequest(
      instructions: leading.map(\.content).joined(separator: "\n\n"),
      entries: entries(for: conversation), prompt: prompt)
  }

  static func entries(for messages: [ModelMessage]) -> [Transcript.Entry] {
    var entries: [Transcript.Entry] = []
    var toolNames: [String: String] = [:]
    var index = 0
    while index < messages.count {
      let message = messages[index]
      defer { index += 1 }
      switch message.role {
      case .system, .user:
        entries.append(prompt(message.content))

      case .assistant where message.toolCalls.isEmpty:
        entries.append(
          .response(
            Transcript.Response(assetIDs: [], segments: [text(message.content)])))

      case .assistant:
        // Only pass a call through if every output that answers it follows immediately.
        let followers = messages[(index + 1)...].prefix { $0.role == .tool }
        let answered = Set(followers.compactMap(\.toolCallID))
        guard message.toolCalls.allSatisfy({ answered.contains($0.id) }) else { continue }
        for call in message.toolCalls { toolNames[call.id] = call.name }
        entries.append(
          .toolCalls(
            Transcript.ToolCalls(
              message.toolCalls.map { call in
                Transcript.ToolCall(
                  id: call.id, toolName: call.name, arguments: content(for: call.arguments))
              })))

      case .tool:
        if let id = message.toolCallID, let name = toolNames[id] {
          entries.append(
            .toolOutput(
              Transcript.ToolOutput(id: id, toolName: name, segments: [text(message.content)])))
        } else {
          entries.append(prompt("Result: " + message.content))
        }
      }
    }
    return entries
  }

  /// The instructions entry, with the tool definitions the model may call.
  static func instructionsEntry(
    _ instructions: String, tools: [Transcript.ToolDefinition]
  ) -> Transcript.Entry? {
    guard !instructions.isEmpty || !tools.isEmpty else { return nil }
    return .instructions(
      Transcript.Instructions(
        segments: instructions.isEmpty ? [] : [text(instructions)], toolDefinitions: tools))
  }

  static func promptEntry(_ content: String) -> Transcript.Entry { prompt(content) }

  private static func prompt(_ content: String) -> Transcript.Entry {
    .prompt(Transcript.Prompt(segments: [text(content)]))
  }

  private static func text(_ content: String) -> Transcript.Segment {
    .text(Transcript.TextSegment(content: content))
  }

  private static func content(for arguments: ToolArguments) -> GeneratedContent {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(JSONValue.object(arguments.values)),
      let json = String(data: data, encoding: .utf8),
      let content = try? GeneratedContent(json: json)
    else { return GeneratedContent(properties: [:]) }
    return content
  }
}
