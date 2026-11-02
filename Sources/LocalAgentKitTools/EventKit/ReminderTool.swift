import Foundation
import LocalAgentKitCore

/// Create a reminder (FR-008). `.userConfirmation`: the runtime holds this for a human's yes
/// before it ever reaches ``execute(arguments:)``.
public struct ReminderTool: AgentTool {
  /// Registered action name `create_reminder`.
  public let name = "create_reminder"
  /// Prompt-facing guidance for creating a reminder with an optional due date.
  public let description =
    "Create a reminder for the user, optionally with a due date and time."
  /// Requires a title; an optional due value is an ISO 8601 date-time.
  public let schema = ToolSchema(
    parameters: [
      "title": ToolParameter(.string, description: "Short title of the reminder."),
      "due": ToolParameter(
        .string,
        description: "When the reminder is due, an ISO 8601 date-time. Omit if none was given."),
    ], required: ["title"])
  /// Requires human confirmation before creating user data through the runtime.
  public let permission = ToolPermission.userConfirmation
  /// True: device-store access is serialized by its actor.
  public let isParallelSafe = true
  /// Advertises cancellation support to the executor; an already-saved reminder is not rolled back.
  public let isCancellable = true
  private let store: any EventStoring

  /// Creates a reminder tool backed by the device's EventKit store.
  public init() {
    self.init(store: EventStoreProvider())
  }

  init(store: any EventStoring) {
    self.store = store
  }

  /// Creates a reminder after title/date validation and EventKit authorization.
  /// Returns the saved identifier; direct calls do not perform the runtime's confirmation step.
  public func execute(arguments: ToolArguments) async throws -> ToolResult {
    guard let title = arguments.string("title"), !title.isEmpty else {
      throw AgentError.invalidArguments(tool: name, violations: [.missingRequired(path: "title")])
    }
    var due: DateComponents?
    if let dueText = arguments.string("due"), !dueText.isEmpty {
      guard let date = LenientISO8601.date(from: dueText) else {
        throw AgentError.invalidArguments(
          tool: name, violations: [.typeMismatch(path: "due", expected: "an ISO 8601 date-time")])
      }
      due = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
    let id = try await store.createReminder(title: title, due: due, notes: nil)
    return ToolResult(
      callID: "", toolName: name, text: "Created reminder \"\(title)\".", structured: .string(id))
  }
}
