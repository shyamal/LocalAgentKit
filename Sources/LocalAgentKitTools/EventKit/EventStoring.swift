import Foundation
import LocalAgentKitCore

/// The seam `CalendarTool`/`ReminderTool` use instead of talking to EventKit directly.
///
/// This is a Tools-internal implementation detail, not one of Core's public extensibility
/// protocols, so its mock lives with the tests that use it (`Tests/LocalAgentKitToolsTests`)
/// rather than in `LocalAgentKitTesting`, which depends on Core only and cannot depend on Tools.
protocol EventStoring: Sendable {
  /// - Throws: `.deviceAuthorizationDenied(.calendar)` if access is not granted.
  func events(from start: Date, to end: Date) async throws -> [[String: JSONValue]]

  /// - Returns: The created reminder's identifier.
  /// - Throws: `.deviceAuthorizationDenied(.reminders)` if access is not granted.
  @discardableResult
  func createReminder(title: String, due: DateComponents?, notes: String?) async throws -> String
}
