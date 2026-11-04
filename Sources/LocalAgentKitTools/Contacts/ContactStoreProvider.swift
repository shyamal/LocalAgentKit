import Contacts
import Foundation
import LocalAgentKitCore

/// The device framework stays here. Constructing the tool does not fetch or request authorization.
actor ContactStoreProvider: ContactSearching {
  private var backingStore: CNContactStore?
  private var store: CNContactStore {
    if let backingStore { return backingStore }
    let value = CNContactStore()
    backingStore = value
    return value
  }

  func search(query: String, limit: Int) async throws -> [ContactSummary] {
    try checkCancellation()
    guard limit > 0, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return []
    }
    try await requireAccess()
    try checkCancellation()
    let keys = [
      CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey,
      CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactEmailAddressesKey,
      CNContactPhoneNumbersKey,
    ].map { $0 as CNKeyDescriptor }
    let request = CNContactFetchRequest(keysToFetch: keys)
    request.unifyResults = true
    request.sortOrder = .userDefault
    var matches: [ContactSummary] = []
    do {
      // Compound company/role predicates are unsupported by Contacts. Enumerate accessible
      // cards in store order, matching locally and stopping as soon as the limit is reached.
      try store.enumerateContacts(with: request) { contact, stop in
        if Task.isCancelled {
          stop.pointee = true
          return
        }
        let value = Self.summary(contact)
        if value.matches(query: query) { matches.append(value) }
        if matches.count >= limit { stop.pointee = true }
      }
      try checkCancellation()
      return matches
    } catch { throw Self.mapped(error) }
  }

  private func requireAccess() async throws {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    if Self.isAuthorized(status) { return }
    switch status {
    case .authorized: return
    case .denied, .restricted: throw AgentError.deviceAuthorizationDenied(.contacts)
    case .notDetermined:
      guard
        let purpose = Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription")
          as? String,
        !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw AgentError.toolFailed(
          tool: "search_contacts",
          message:
            "The host app must set NSContactsUsageDescription before requesting contact access.")
      }
      do {
        _ = try await store.requestAccess(for: .contacts)
        try checkCancellation()
        guard Self.isAuthorized(CNContactStore.authorizationStatus(for: .contacts)) else {
          throw AgentError.deviceAuthorizationDenied(.contacts)
        }
      } catch { throw Self.mapped(error) }
    #if os(iOS)
      case .limited: return
    #endif
    @unknown default: throw AgentError.deviceAuthorizationDenied(.contacts)
    }
  }

  static func isAuthorized(_ status: CNAuthorizationStatus) -> Bool {
    switch status {
    case .authorized: true
    #if os(iOS)
      case .limited: true
    #endif
    default: false
    }
  }

  static func summary(_ contact: CNContact) -> ContactSummary {
    let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
    return ContactSummary(
      id: contact.identifier, name: name.isEmpty ? contact.organizationName : name,
      organization: contact.organizationName, jobTitle: contact.jobTitle,
      emails: Array(contact.emailAddresses.prefix(2)).map { $0.value as String },
      phoneNumbers: Array(contact.phoneNumbers.prefix(2)).map { $0.value.stringValue })
  }

  static func mapped(_ error: any Error) -> AgentError {
    if let error = error as? AgentError { return error }
    if error is CancellationError { return .cancelled }
    let nsError = error as NSError
    if nsError.domain == CNErrorDomain, nsError.code == CNError.Code.authorizationDenied.rawValue {
      return .deviceAuthorizationDenied(.contacts)
    }
    return .toolFailed(tool: "search_contacts", message: error.localizedDescription)
  }

  private func checkCancellation() throws {
    if Task.isCancelled { throw AgentError.cancelled }
  }
}
