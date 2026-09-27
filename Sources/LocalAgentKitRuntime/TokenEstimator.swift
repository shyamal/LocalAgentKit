import LocalAgentKitCore

/// A cheap, deliberately pessimistic token estimate, used to decide *what* to trim. It is
/// calibrated against the provider's real count whenever one exists, and it is the only count
/// where a provider has none. Not a substitute for `tokenCount(for:)`.
enum TokenEstimator {
  static let charactersPerToken = 3.0
  static let perMessageOverhead = 4

  static func tokens(_ text: String) -> Int {
    Int((Double(text.utf8.count) / charactersPerToken).rounded(.up))
  }

  static func tokens(_ message: ModelMessage) -> Int {
    var total = perMessageOverhead + tokens(message.content)
    for call in message.toolCalls {
      total += tokens(call.name) + tokens(call.arguments.signature) + 2
    }
    return total
  }

  static func tokens(_ tool: ToolDescriptor) -> Int {
    tokens(tool.name) + tokens(tool.description) + tokens(tool.schema) + 4
  }

  static func tokens(_ schema: ToolSchema) -> Int {
    schema.parameters.reduce(0) { total, entry in
      total + tokens(entry.key) + tokens(entry.value.description)
        + tokens(entry.value.allowedValues?.joined(separator: ",") ?? "") + 6
    }
  }

  static func tokens(_ request: ModelRequest) -> Int {
    request.messages.reduce(0) { $0 + tokens($1) } + request.tools.reduce(0) { $0 + tokens($1) }
  }
}
