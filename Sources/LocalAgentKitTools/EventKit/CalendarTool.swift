import Foundation
import LocalAgentKitCore

/// Read the user's calendar events (FR-008). `.readOnly`.
public struct CalendarTool: AgentTool {
  /// Registered action name `list_calendar_events`.
  public let name = "list_calendar_events"
  /// Prompt-facing guidance for reading events that overlap an interval.
  public let description = "List the user's calendar events that overlap a time range."
  /// Requires start and end date-time strings.
  public let schema = ToolSchema(
    parameters: [
      "start": ToolParameter(.string, description: "Range start, an ISO 8601 date-time."),
      "end": ToolParameter(.string, description: "Range end, an ISO 8601 date-time."),
    ], required: ["start", "end"])
  /// Read-only agent tier; EventKit authorization is still required.
  public let permission = ToolPermission.readOnly
  /// True: device-store access is serialized by its actor.
  public let isParallelSafe = true
  /// Advertises cancellation support to the executor; system operations may finish after cancellation.
  public let isCancellable = true
  private let store: any EventStoring

  /// Creates a tool backed by the device's EventKit store.
  public init() {
    self.init(store: EventStoreProvider())
  }

  init(store: any EventStoring) {
    self.store = store
  }

  /// Parses interval dates and reads authorized calendar events.
  /// Returns compact text and structured events; authorization and date errors are typed AgentError values.
  public func execute(arguments: ToolArguments) async throws -> ToolResult {
    guard let start = try parseDate(arguments, "start") else {
      throw AgentError.invalidArguments(tool: name, violations: [.missingRequired(path: "start")])
    }
    guard let end = try parseDate(arguments, "end") else {
      throw AgentError.invalidArguments(tool: name, violations: [.missingRequired(path: "end")])
    }
    let events = try await store.events(from: start, to: end)
    guard !events.isEmpty else {
      return ToolResult(callID: "", toolName: name, text: "No events found.", isEmpty: true)
    }
    let text = events.map(Self.describe).joined(separator: "\n")
    return ToolResult(
      callID: "", toolName: name, text: text, structured: .array(events.map(JSONValue.object)))
  }

  /// - Throws: `.invalidArguments` when the value is present but not a date, so the runtime's
  ///   repair path can ask the model to correct it rather than treating it as missing.
  private func parseDate(_ arguments: ToolArguments, _ field: String) throws -> Date? {
    guard let text = arguments.string(field) else { return nil }
    guard let date = LenientISO8601.date(from: text) else {
      throw AgentError.invalidArguments(
        tool: name, violations: [.typeMismatch(path: field, expected: "an ISO 8601 date-time")])
    }
    return date
  }

  private static func describe(_ event: [String: JSONValue]) -> String {
    let title = event["title"].flatMap(\.stringValue) ?? "Untitled"
    let start = event["start"].flatMap(\.stringValue) ?? ""
    let end = event["end"].flatMap(\.stringValue) ?? ""
    return "\(title): \(start) – \(end)"
  }
}

extension JSONValue {
  fileprivate var stringValue: String? {
    if case .string(let value) = self { value } else { nil }
  }
}
