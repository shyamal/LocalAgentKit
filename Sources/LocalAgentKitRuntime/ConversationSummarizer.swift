import LocalAgentKitCore

/// Condenses older conversation turns when the context is full (M1-RT-05).
public protocol ConversationSummarizer: Sendable {
  /// - Parameter messages: Earlier conversation messages to compact.
  /// - Parameter maxTokens: An upper bound on the summary's size, which the caller relies on.
  func summarize(_ messages: [ModelMessage], maxTokens: Int) async throws -> String
}

/// A deterministic summary that never calls the model. A model-written summary costs a model call
/// — battery on a phone that reaches `.serious` thermal state in five minutes (findings §16) —
/// and on macOS 26 the model ignores facts already in its window (findings §14), so the default
/// keeps what was asked and which tools ran, and does not paraphrase.
public struct ExtractiveSummarizer: ConversationSummarizer {
  public static let header = "Summary of earlier conversation (older turns were shortened):"

  public init() {}

  public func summarize(_ messages: [ModelMessage], maxTokens: Int) async throws -> String {
    var lines: [String] = []
    for message in messages {
      switch message.role {
      case .user:
        lines.append("- User: \(Self.clip(message.content, 100))")
      case .assistant:
        if !message.toolCalls.isEmpty {
          lines.append("- Called " + message.toolCalls.map(\.name).joined(separator: ", "))
        } else if !message.content.isEmpty {
          lines.append("- Assistant: \(Self.clip(message.content, 100))")
        }
      case .tool, .system:
        continue
      }
    }
    var summary = Self.header
    // Keep the newest lines: they are closest to the live conversation.
    var body = ""
    for line in lines.reversed() {
      let candidate = "\n" + line + body
      if TokenEstimator.tokens(summary + candidate) > maxTokens { break }
      body = candidate
    }
    summary += body
    return summary
  }

  private static func clip(_ text: String, _ limit: Int) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
  }
}
