import LocalAgentKitCore
import LocalAgentKitRuntime

/// Durable context-pressure corpus, translated into the SDK's separate budget sections.
public struct ContextLoadFixture: Decodable, Sendable {
  public struct Entry: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable { case prompt, response, toolCall, toolOutput }
    public let kind: Kind
    public let text: String?
    public let tool: String?
    public let arguments: [String: JSONValue]?
  }
  public struct Exchange: Decodable, Sendable {
    public let exchange: Int
    public let entries: [Entry]
  }
  public struct Chunk: Decodable, Sendable {
    public let id: String
    public let doc: String
    public let section: String
    public let text: String
    var formatted: String { "[\(doc) - \(section)]\n\(text)" }
  }
  public struct Plan: Decodable, Sendable {
    public struct Step: Decodable, Sendable {
      public let n: Int
      public let status: String
      public let description: String
      public let note: String?
      var formatted: String { "\(n). [\(status)] \(description)" + (note.map { " - \($0)" } ?? "") }
    }
    public let goal: String
    public let steps: [Step]
  }
  public struct Profile: Decodable, Sendable {
    public let id: String
    public let exchanges: Int
    public let chunks: Int
    public let plan: Bool
  }
  public struct Probe: Decodable, Sendable {
    public struct Source: Decodable, Sendable {
      public let exchange: Int?
      public let chunk: String?
      public let plan: Int?
    }
    public let id: String
    public let question: String
    public let answerContainsAny: [String]
    public let source: Source
  }
  public struct Assembly: Decodable, Sendable { public let promptSuffix: String }
  public let fixture: String
  public let version: Int
  public let assembly: Assembly
  public let instructions: String
  public let conversation: [Exchange]
  public let chunks: [Chunk]
  public let plan: Plan
  public let probes: [Probe]
  public let profiles: [Profile]

  /// Preserves complete history turns and call/output IDs. Retrieved chunks and plan are not
  /// hidden in the final question, so ContextBudgeter can allocate their own shares.
  public func inputs(profile: Profile, probe: Probe, tools: [ToolDescriptor]) throws
    -> ContextInputs
  {
    guard profile.exchanges >= 0, profile.exchanges <= conversation.count,
      profile.chunks >= 0, profile.chunks <= chunks.count
    else {
      throw ProbeError.invalidOptions("Profile \(profile.id) exceeds the corpus.")
    }
    var history: [ModelMessage] = []
    for exchange in conversation.suffix(profile.exchanges) {
      var pending: ToolCall?
      for (index, entry) in exchange.entries.enumerated() {
        switch entry.kind {
        case .prompt: history.append(ModelMessage(role: .user, content: entry.text ?? ""))
        case .response: history.append(ModelMessage(role: .assistant, content: entry.text ?? ""))
        case .toolCall:
          guard pending == nil, let tool = entry.tool else {
            throw ProbeError.invalidOptions("Invalid history tool call.")
          }
          let call = ToolCall(
            id: "history-\(exchange.exchange)-\(index)", name: tool,
            arguments: ToolArguments(entry.arguments ?? [:]))
          pending = call
          history.append(ModelMessage(role: .assistant, content: "", toolCalls: [call]))
        case .toolOutput:
          guard let call = pending, entry.tool == call.name else {
            throw ProbeError.invalidOptions("Unpaired history output.")
          }
          history.append(ModelMessage(role: .tool, content: entry.text ?? "", toolCallID: call.id))
          pending = nil
        }
      }
      guard pending == nil else { throw ProbeError.invalidOptions("Unanswered history call.") }
    }
    history.append(
      ModelMessage(role: .user, content: probe.question + "\n" + assembly.promptSuffix))
    return ContextInputs(
      instructions: instructions, tools: tools, requiredToolNames: Set(tools.map(\.name)),
      conversation: history, retrievedChunks: chunks.prefix(profile.chunks).map(\.formatted),
      planState: profile.plan
        ? ([plan.goal] + plan.steps.map(\.formatted)).joined(separator: "\n") : nil)
  }

  public func sourceIncluded(_ probe: Probe, profile: Profile) -> Bool {
    if let id = probe.source.exchange {
      return conversation.suffix(profile.exchanges).contains { $0.exchange == id }
    }
    if let id = probe.source.chunk { return chunks.prefix(profile.chunks).contains { $0.id == id } }
    return probe.source.plan != nil && profile.plan
  }

  /// Strict source fragments distinguish retained evidence from coincidental answer words.
  func sourceFragments(_ probe: Probe) -> [String] {
    if let id = probe.source.exchange {
      return conversation.first { $0.exchange == id }?.entries.compactMap(\.text).filter { text in
        probe.answerContainsAny.contains { text.lowercased().contains($0.lowercased()) }
      } ?? []
    }
    if let id = probe.source.chunk {
      return chunks.first { $0.id == id }.map { [$0.formatted] } ?? []
    }
    if let n = probe.source.plan {
      return plan.steps.first { $0.n == n }.map { [$0.formatted] } ?? []
    }
    return []
  }
}
