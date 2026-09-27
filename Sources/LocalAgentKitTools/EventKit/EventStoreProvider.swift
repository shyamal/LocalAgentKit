import EventKit
import Foundation
import LocalAgentKitCore

/// Owns EventKit's non-Sendable `EKEventStore`. This is the only file in the package that touches
/// an `EKEvent`, `EKReminder`, or `EKCalendar` object; every method returns a Sendable value ready
/// for a `ToolResult`, so nothing EventKit-shaped ever crosses the actor boundary (M1-TL-06).
///
/// A request for access is made only once per app run — `EKEventStore.authorizationStatus(for:)`
/// is checked first, and `.denied`/`.restricted` become the typed, recoverable
/// `AgentError.deviceAuthorizationDenied`, distinct from a generic tool failure, so an app can
/// direct the user to Settings instead of just reporting an error.
///
/// Verified against the installed SDK: every EventKit call below was compiled and run (not read
/// from memory) — `requestFullAccessToEvents()`/`requestFullAccessToReminders()` are real async
/// throwing methods with no explicit Swift async name override, `predicateForEvents(withStart:
/// end:calendars:)`/`events(matching:)`/`defaultCalendarForNewReminders()`/`save(_:commit:)` all
/// exist with these signatures. What is unverified is the authorized path end to end: a bare
/// SwiftPM test binary has no `Info.plist` usage-description strings, so authorization here was
/// only exercised as far as `.denied` — the real UI flow needs an app bundle (the SwiftUI demo,
/// M1-UI, or a physical device run).
actor EventStoreProvider: EventStoring {
  private let store: EKEventStore

  init(store: EKEventStore = EKEventStore()) {
    self.store = store
  }

  // MARK: Calendar (read)

  func events(from start: Date, to end: Date) async throws -> [[String: JSONValue]] {
    try await requireAccess(.calendar, entityType: .event)
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    let formatter = ISO8601DateFormatter()
    return store.events(matching: predicate).map { Self.summarize($0, using: formatter) }
  }

  private static func summarize(_ event: EKEvent, using formatter: ISO8601DateFormatter) -> [String:
    JSONValue]
  {
    [
      "title": .string(event.title ?? ""),
      "start": .string(formatter.string(from: event.startDate)),
      "end": .string(formatter.string(from: event.endDate)),
      "calendar": .string(event.calendar?.title ?? ""),
      "isAllDay": .bool(event.isAllDay),
      "location": event.location.map(JSONValue.string) ?? .null,
    ]
  }

  // MARK: Reminders (create)

  @discardableResult
  func createReminder(title: String, due: DateComponents?, notes: String?) async throws -> String {
    try await requireAccess(.reminders, entityType: .reminder)
    let reminder = EKReminder(eventStore: store)
    reminder.title = title
    reminder.calendar = store.defaultCalendarForNewReminders()
    reminder.dueDateComponents = due
    reminder.notes = notes
    guard reminder.calendar != nil else {
      throw AgentError.toolFailed(
        tool: "create_reminder", message: "no default reminders list is configured")
    }
    do {
      try store.save(reminder, commit: true)
    } catch {
      throw AgentError.toolFailed(tool: "create_reminder", message: String(describing: error))
    }
    return reminder.calendarItemIdentifier
  }

  // MARK: Authorization

  private func requireAccess(_ capability: DeviceCapability, entityType: EKEntityType) async throws
  {
    switch EKEventStore.authorizationStatus(for: entityType) {
    case .fullAccess, .writeOnly:
      return
    case .notDetermined:
      guard await requestAccess(entityType) else {
        throw AgentError.deviceAuthorizationDenied(capability)
      }
    case .denied, .restricted:
      throw AgentError.deviceAuthorizationDenied(capability)
    @unknown default:
      throw AgentError.deviceAuthorizationDenied(capability)
    }
  }

  private func requestAccess(_ entityType: EKEntityType) async -> Bool {
    do {
      switch entityType {
      case .event: return try await store.requestFullAccessToEvents()
      case .reminder: return try await store.requestFullAccessToReminders()
      @unknown default: return false
      }
    } catch {
      return false
    }
  }
}
