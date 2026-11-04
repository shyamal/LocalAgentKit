import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitProviders

@Suite struct EpisodicMemoryStoreTests {
  @Test(arguments: [false, true])
  func categoryAndKindFiltersApplyBeforeLimits(useMock: Bool) async throws {
    let store: any MemoryStore =
      useMock
      ? MockMemoryStore() : try SwiftDataMemoryStore(storage: .inMemory)
    let date = Date(timeIntervalSince1970: 100)
    for index in 0..<8 {
      try await store.save(Memory(content: "Budget review ordinary \(index)"))
    }
    let fact = SemanticMemory(kind: .fact, content: "Budget review owner is Priya")
    try await store.save(fact)
    let event = EpisodicMemory(
      kind: .event, content: "Budget review meeting ended", occurredAt: date, createdAt: date)
    let action = EpisodicMemory(
      kind: .action, content: "Budget review checklist saved", occurredAt: date, createdAt: date)
    try await store.save(event)
    try await store.save(action)
    #expect(try await store.searchEpisodic(text: "Budget", kind: .action, limit: 1) == [action])
    #expect(try await store.searchEpisodic(text: "ended", kind: .event) == [event])
    #expect(try await store.searchEpisodic(text: "Budget", limit: 20).count == 2)
    #expect(try await store.searchSemantic(text: "Budget") == [fact])
    #expect(try await store.searchEpisodic(text: "", limit: 0).isEmpty)
    #expect(try await store.searchEpisodic(text: "", limit: -1).isEmpty)
    #expect(try await store.searchEpisodic(text: "missing").isEmpty)
    #expect(try await store.search(MemoryQuery(text: "ordinary", limit: 20)).count == 8)
  }

  @Test func correctionsAndDeletionPersistAcrossFileReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("episodic.store")
    let event = EpisodicMemory(
      kind: .event, content: "Budget review ended", occurredAt: Date(timeIntervalSince1970: 100),
      metadata: ["source": "calendar"])
    let corrected = try await seedAndCorrect(event, at: url)
    let store = try SwiftDataMemoryStore(storage: .file(url))
    #expect(try await store.searchEpisodic(text: "", kind: .action) == [corrected])
    #expect(try await store.searchEpisodic(text: "", kind: .event).isEmpty)
    #expect(try await store.searchEpisodic(text: "ended").isEmpty)
    try await store.delete(id: corrected.id)
    try await store.delete(id: corrected.id)
    let reopened = try SwiftDataMemoryStore(storage: .file(url))
    #expect(try await reopened.searchEpisodic(text: "").isEmpty)
  }

  @Test func swiftDataOrderingUsesRecordingDateNotOccurrenceDate() async throws {
    let store = try SwiftDataMemoryStore(storage: .inMemory)
    let date = Date(timeIntervalSince1970: 100)
    let recentRecording = EpisodicMemory(
      kind: .event, content: "Recorded later but occurred earlier", occurredAt: date,
      createdAt: date.addingTimeInterval(200))
    let recentOccurrence = EpisodicMemory(
      kind: .event, content: "Occurred later but recorded earlier",
      occurredAt: date.addingTimeInterval(100), createdAt: date)
    try await store.save(recentRecording)
    try await store.save(recentOccurrence)
    #expect(try await store.searchEpisodic(text: "", limit: 1) == [recentRecording])
  }

  @Test(arguments: [false, true])
  func malformedMatchingEpisodesFailInsteadOfDisappearing(useMock: Bool) async throws {
    let store: any MemoryStore =
      useMock
      ? MockMemoryStore() : try SwiftDataMemoryStore(storage: .inMemory)
    var record = try EpisodicMemory(kind: .event, content: "Invalid", occurredAt: Date()).memory()
    record.metadata["localagentkit.episodic.version"] = "99"
    try await store.save(record)
    await #expect(
      throws: AgentError.memoryFailure("Invalid or unsupported episodic memory record.")
    ) {
      try await store.searchEpisodic(text: "")
    }
  }

  @Test func cancelledCallsDoNotWriteOrSearch() async throws {
    let store = MockMemoryStore()
    let event = EpisodicMemory(kind: .event, content: "Do not save", occurredAt: Date())
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await #expect(throws: AgentError.cancelled) { try await store.save(event) }
      await #expect(throws: AgentError.cancelled) { try await store.searchEpisodic(text: "") }
    }
    await task.value
    #expect(await store.all.isEmpty)
  }

  @Test func invalidCorrectionLeavesSavedEpisodeUnchanged() async throws {
    let store = try SwiftDataMemoryStore(storage: .inMemory)
    var event = EpisodicMemory(kind: .event, content: "Retain this", occurredAt: Date())
    try await store.save(event)
    event.content = " "
    await #expect(throws: AgentError.memoryFailure("Episodic memory content must not be blank.")) {
      try await store.save(event)
    }
    #expect(try await store.searchEpisodic(text: "").first?.content == "Retain this")
  }

  private func seedAndCorrect(_ event: EpisodicMemory, at url: URL) async throws -> EpisodicMemory {
    let store = try SwiftDataMemoryStore(storage: .file(url))
    try await store.save(event)
    var corrected = event
    corrected.kind = .action
    corrected.content = "Saved Budget review checklist"
    corrected.occurredAt = event.occurredAt.addingTimeInterval(600)
    corrected.metadata = ["source": "approval"]
    try await store.save(corrected)
    return corrected
  }
}
