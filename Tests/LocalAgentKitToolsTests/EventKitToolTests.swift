import Foundation
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitTools

private actor FakeEventStore: EventStoring {
  var eventsResult: [[String: JSONValue]] = []
  var eventsError: AgentError?
  var createdReminders: [(title: String, due: DateComponents?, notes: String?)] = []
  var createError: AgentError?
  private(set) var eventsCalls: [(start: Date, end: Date)] = []

  func events(from start: Date, to end: Date) async throws -> [[String: JSONValue]] {
    eventsCalls.append((start, end))
    if let eventsError { throw eventsError }
    return eventsResult
  }

  func createReminder(title: String, due: DateComponents?, notes: String?) async throws -> String {
    if let createError { throw createError }
    createdReminders.append((title, due, notes))
    return "id-\(createdReminders.count)"
  }
}

@Suite struct CalendarToolTests {
  @Test func propertiesMatchFR008() {
    let tool = CalendarTool()
    #expect(tool.name == "list_calendar_events")
    #expect(tool.permission == .readOnly)
    #expect(tool.schema.required == ["start", "end"])
  }

  @Test func missingStartOrEndIsInvalidArguments() async {
    let tool = CalendarTool(store: FakeEventStore())
    await #expect(
      throws: AgentError.invalidArguments(
        tool: "list_calendar_events", violations: [.missingRequired(path: "start")])
    ) {
      try await tool.execute(arguments: ToolArguments(["end": "2026-09-22T10:00"]))
    }
    await #expect(
      throws: AgentError.invalidArguments(
        tool: "list_calendar_events", violations: [.missingRequired(path: "end")])
    ) {
      try await tool.execute(arguments: ToolArguments(["start": "2026-09-22T09:00"]))
    }
  }

  @Test func unparseableDateIsInvalidArgumentsNotMissing() async {
    let tool = CalendarTool(store: FakeEventStore())
    await #expect(
      throws: AgentError.invalidArguments(
        tool: "list_calendar_events",
        violations: [.typeMismatch(path: "start", expected: "an ISO 8601 date-time")])
    ) {
      try await tool.execute(
        arguments: ToolArguments(["start": "tomorrow", "end": "2026-09-22T10:00"]))
    }
  }

  @Test func acceptsEveryDateShapePhase0Observed() async throws {
    let fake = FakeEventStore()
    let tool = CalendarTool(store: fake)
    for (start, end) in [
      ("2026-09-22T09:00", "2026-09-22T10:00"),
      ("2026-09-22T09:00:00", "2026-09-22T10:00:00"),
      ("2026-09-22T09:00:00Z", "2026-09-22T10:00:00Z"),
      ("2026-09-22T09:00:00+00:00", "2026-09-22T10:00:00+00:00"),
    ] {
      _ = try await tool.execute(
        arguments: ToolArguments(["start": .string(start), "end": .string(end)]))
    }
    #expect(await fake.eventsCalls.count == 4)
  }

  @Test func noEventsIsAnEmptyResultWithClearText() async throws {
    let tool = CalendarTool(store: FakeEventStore())
    let result = try await tool.execute(
      arguments: ToolArguments(["start": "2026-09-22T09:00", "end": "2026-09-22T10:00"]))
    #expect(result.isEmpty)
    #expect(result.text == "No events found.")
  }

  @Test func eventsAreDescribedAndStructured() async throws {
    let fake = FakeEventStore()
    await fake.setEvents([
      ["title": "Standup", "start": "2026-09-22T09:00:00Z", "end": "2026-09-22T09:15:00Z"]
    ])
    let tool = CalendarTool(store: fake)
    let result = try await tool.execute(
      arguments: ToolArguments(["start": "2026-09-22T00:00", "end": "2026-09-23T00:00"]))
    #expect(!result.isEmpty)
    #expect(result.text.contains("Standup"))
    #expect(result.structured != nil)
  }

  @Test func deviceAuthorizationDenialPassesThroughTyped() async {
    let fake = FakeEventStore()
    await fake.setEventsError(.deviceAuthorizationDenied(.calendar))
    let tool = CalendarTool(store: fake)
    await #expect(throws: AgentError.deviceAuthorizationDenied(.calendar)) {
      try await tool.execute(
        arguments: ToolArguments(["start": "2026-09-22T09:00", "end": "2026-09-22T10:00"]))
    }
  }
}

@Suite struct ReminderToolTests {
  @Test func propertiesMatchFR008() {
    let tool = ReminderTool()
    #expect(tool.name == "create_reminder")
    #expect(tool.permission == .userConfirmation)
    #expect(tool.schema.required == ["title"])
  }

  @Test func missingTitleIsInvalidArguments() async {
    let tool = ReminderTool(store: FakeEventStore())
    await #expect(
      throws: AgentError.invalidArguments(
        tool: "create_reminder", violations: [.missingRequired(path: "title")])
    ) {
      try await tool.execute(arguments: ToolArguments())
    }
  }

  @Test func emptyTitleIsInvalidArgumentsToo() async {
    let tool = ReminderTool(store: FakeEventStore())
    await #expect(throws: AgentError.self) {
      try await tool.execute(arguments: ToolArguments(["title": ""]))
    }
  }

  @Test func createsWithNoDueDate() async throws {
    let fake = FakeEventStore()
    let tool = ReminderTool(store: fake)
    let result = try await tool.execute(arguments: ToolArguments(["title": "Buy milk"]))
    #expect(result.text.contains("Buy milk"))
    let created = await fake.createdReminders
    #expect(created.count == 1)
    #expect(created[0].title == "Buy milk")
    #expect(created[0].due == nil)
  }

  @Test func createsWithADueDateParsedFromText() async throws {
    let fake = FakeEventStore()
    let tool = ReminderTool(store: fake)
    _ = try await tool.execute(
      arguments: ToolArguments(["title": "Call plumber", "due": "2026-09-30T09:00"]))
    let due = try #require(await fake.createdReminders.first?.due)
    #expect(due.year == 2026)
    #expect(due.month == 9)
    #expect(due.day == 30)
    #expect(due.hour == 9)
    #expect(due.minute == 0)
  }

  @Test func emptyDueIsTreatedAsOmitted() async throws {
    let fake = FakeEventStore()
    let tool = ReminderTool(store: fake)
    _ = try await tool.execute(arguments: ToolArguments(["title": "Buy milk", "due": ""]))
    #expect(await fake.createdReminders.first?.due == nil)
  }

  @Test func unparseableDueIsInvalidArguments() async {
    let tool = ReminderTool(store: FakeEventStore())
    await #expect(
      throws: AgentError.invalidArguments(
        tool: "create_reminder",
        violations: [.typeMismatch(path: "due", expected: "an ISO 8601 date-time")])
    ) {
      try await tool.execute(arguments: ToolArguments(["title": "x", "due": "next tuesday"]))
    }
  }

  @Test func deviceAuthorizationDenialPassesThroughTyped() async {
    let fake = FakeEventStore()
    await fake.setCreateError(.deviceAuthorizationDenied(.reminders))
    let tool = ReminderTool(store: fake)
    await #expect(throws: AgentError.deviceAuthorizationDenied(.reminders)) {
      try await tool.execute(arguments: ToolArguments(["title": "x"]))
    }
  }
}

@Suite struct LenientISO8601Tests {
  @Test func acceptsEveryShapePhase0Observed() {
    let utc = TimeZone(identifier: "UTC")!
    for text in [
      "2026-09-22T09:00", "2026-09-22T09:00:00", "2026-09-22T09:00:00Z",
      "2026-09-22T09:00:00+00:00", "2026-09-22T09:00Z",
    ] {
      #expect(LenientISO8601.date(from: text, timeZone: utc) != nil, "failed to parse \(text)")
    }
  }

  @Test func rejectsGarbage() {
    #expect(LenientISO8601.date(from: "") == nil)
    #expect(LenientISO8601.date(from: "tomorrow") == nil)
    #expect(LenientISO8601.date(from: "09-22-2026") == nil)
  }

  @Test func noOffsetFormatsUseTheGivenTimeZone() {
    let utc = LenientISO8601.date(from: "2026-09-22T09:00", timeZone: TimeZone(identifier: "UTC")!)
    let offset = LenientISO8601.date(
      from: "2026-09-22T09:00", timeZone: TimeZone(identifier: "America/New_York")!)
    #expect(utc != offset)
  }
}

extension FakeEventStore {
  func setEvents(_ events: [[String: JSONValue]]) { eventsResult = events }
  func setEventsError(_ error: AgentError) { eventsError = error }
  func setCreateError(_ error: AgentError) { createError = error }
}
