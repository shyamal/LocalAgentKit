import Foundation
import LocalAgentKitCore

/// Search local contact cards (FR-008). Reading this personal data requires human approval.
public struct ContactsTool: AgentTool {
  /// Registered action name.
  public let name = "search_contacts"
  /// Model-facing guidance with no destination, sending or mutation capability.
  public let description =
    "Search local contacts by name, company, or job title. Returns contact cards; requires approval. Does not send messages."
  /// Required search text, checked for non-blank content during execution as well.
  public let schema = ToolSchema(
    parameters: [
      "query": ToolParameter(.string, description: "Name, company, or job title to find.")
    ],
    required: ["query"])
  /// Contact reads themselves are sensitive and always require the runtime's approval gate.
  public let permission = ToolPermission.sensitive
  /// Backend access is serialized; approval prompts are not designed as a parallel contact scan.
  public let isParallelSafe = false
  /// Checks cancellation around backend work; OS prompts/synchronous reads may finish later.
  public let isCancellable = true
  private let store: any ContactSearching
  private let limit: Int

  /// Creates device contact search. The host must provide NSContactsUsageDescription in its app.
  public init(limit: Int = 5) { self.init(store: ContactStoreProvider(), limit: limit) }

  /// Injects a local-only backend (for example MockContactStore). No initializer can weaken the tier.
  /// Results per invocation are clamped to 1...10 to bound prompt disclosure.
  public init(store: any ContactSearching, limit: Int = 5) {
    self.store = store
    self.limit = min(10, max(1, limit))
  }

  /// Returns bounded cards or an explicit empty result. Use AgentRuntime/ToolExecutor for approval;
  /// direct calls invoke the host API without its human gate. OS authorization remains independent.
  public func execute(arguments: ToolArguments) async throws -> ToolResult {
    if Task.isCancelled { throw AgentError.cancelled }
    guard let raw = arguments.string("query"),
      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AgentError.invalidArguments(tool: name, violations: [.missingRequired(path: "query")])
    }
    let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let matches: [ContactSummary]
    do {
      matches = try await store.search(query: query, limit: limit)
    } catch {
      throw ContactStoreProvider.mapped(error)
    }
    if Task.isCancelled { throw AgentError.cancelled }
    let cards = matches.filter { $0.matches(query: query) }.prefix(limit).map(Self.card)
    guard !cards.isEmpty else {
      return ToolResult(
        callID: "", toolName: name, text: "No accessible contacts found.", isEmpty: true)
    }
    return ToolResult(
      callID: "", toolName: name,
      text: cards.enumerated().map { index, card in
        "[\(index + 1)] "
          + ["name", "organization", "job_title", "emails", "phone_numbers"].compactMap { key in
            if case .string(let text)? = card[key], !text.isEmpty { return text }
            if case .array(let values)? = card[key] {
              return values.compactMap { if case .string(let text) = $0 { text } else { nil } }
                .joined(separator: ", ")
            }
            return nil
          }.filter { !$0.isEmpty }.joined(separator: " — ")
      }.joined(separator: "\n"), structured: .array(cards.map(JSONValue.object)))
  }

  private static func card(_ contact: ContactSummary) -> [String: JSONValue] {
    [
      "id": .string(clip(contact.id, 200)), "name": .string(clip(contact.name, 120)),
      "organization": .string(clip(contact.organization, 120)),
      "job_title": .string(clip(contact.jobTitle, 120)),
      "emails": .array(contact.emails.prefix(2).map { .string(clip($0, 160)) }),
      "phone_numbers": .array(contact.phoneNumbers.prefix(2).map { .string(clip($0, 80)) }),
    ]
  }

  private static func clip(_ text: String, _ limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit)) + "…" : text
  }
}
