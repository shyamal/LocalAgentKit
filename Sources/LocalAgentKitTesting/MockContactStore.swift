import Foundation
import LocalAgentKitCore

/// Local, deterministic contact search without address-book access, OS prompts or network use.
public actor MockContactStore: ContactSearching {
  /// Seeded records, retained in insertion order.
  public var contacts: [ContactSummary]
  /// Optional typed backend failure, used to test denial/error propagation.
  public var failure: AgentError?
  /// Query texts received, including calls that subsequently fail.
  public private(set) var queries: [String] = []

  /// Creates a mock contact store with optional records and a configured failure.
  public init(_ contacts: [ContactSummary] = [], failure: AgentError? = nil) {
    self.contacts = contacts
    self.failure = failure
  }

  /// Records a query, checks cancellation and returns bounded matches in insertion order.
  public func search(query: String, limit: Int) async throws -> [ContactSummary] {
    if Task.isCancelled { throw AgentError.cancelled }
    queries.append(query)
    guard limit > 0, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return []
    }
    if let failure { throw failure }
    return Array(contacts.filter { $0.matches(query: query) }.prefix(limit))
  }
}
