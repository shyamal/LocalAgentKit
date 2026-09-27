import Foundation
import LocalAgentKitCore

/// Read the user's calendar events (FR-008). `.readOnly`.
public struct CalendarTool: AgentTool {
  public let name = "list_calendar_events"
  public let description = "List the user's calendar events that overlap a time range."
  public let schema = ToolSchema(
    parameters: [
      "start": ToolParameter(.string, description: "Range start, an ISO 8601 date-time."),
      "end": ToolParameter(.string, description: "Range end, an ISO 8601 date-time."),
    ], required: ["start", "end"])
  public let permission = ToolPermission.readOnly
  public let isParallelSafe = true
  public let isCancellable = true
  private let store: any EventStoring

  public init() {
    self.init(store: EventStoreProvider())
  }

  init(store: any EventStoring) {
    self.store = store
  }

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
