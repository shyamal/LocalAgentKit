import Foundation

/// A framework-independent contact card. No Contacts framework objects cross this boundary.
public struct ContactSummary: Sendable, Hashable, Identifiable {
  /// Device-store identifier; treat it as opaque, app-private data.
  public var id: String
  /// Given and family names joined for display, or the organization for an unnamed card.
  public var name: String
  /// Organization/company field, not inferred from other records.
  public var organization: String
  /// Job-title field, used for role searches.
  public var jobTitle: String
  /// Email addresses included in the card; the tool limits how many enter a prompt.
  public var emails: [String]
  /// Phone-number strings included in the card; the tool limits prompt disclosure.
  public var phoneNumbers: [String]

  /// Creates an app-owned contact value without accessing a device store.
  public init(
    id: String, name: String, organization: String = "", jobTitle: String = "",
    emails: [String] = [], phoneNumbers: [String] = []
  ) {
    self.id = id
    self.name = name
    self.organization = organization
    self.jobTitle = jobTitle
    self.emails = emails
    self.phoneNumbers = phoneNumbers
  }

  /// Localized case/diacritic-insensitive substring matching across name, company or job title.
  /// Blank queries never match; email and phone fields are not search predicates.
  public func matches(query: String) -> Bool {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return !text.isEmpty
      && [name, organization, jobTitle].contains { $0.localizedStandardContains(text) }
  }
}

/// Local contact search, returning only Sendable values. Implementations must not use the network.
/// The caller must enforce the tool's sensitive approval gate before invoking the device backend.
public protocol ContactSearching: Sendable {
  /// Searches name/company/job title with ContactSummary.matches semantics; blank queries or
  /// non-positive limits return none. Ordering is provider-defined. Honor cancellation and throw
  /// typed AgentError values, including deviceAuthorizationDenied(.contacts) for denied OS access.
  func search(query: String, limit: Int) async throws -> [ContactSummary]
}
