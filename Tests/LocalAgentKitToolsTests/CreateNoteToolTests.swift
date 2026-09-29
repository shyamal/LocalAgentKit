import Foundation
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitTools

private func tempDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

@Suite struct NoteStoreTests {
  @Test func savedNotesAreReturnedByAll() async throws {
    let store = NoteStore(directory: tempDirectory())
    try await store.save(Note(title: "Budget", body: "Review Tuesday."))
    try await store.save(Note(title: "Groceries", body: "Milk, eggs."))
    let all = try await store.all()
    #expect(all.map(\.title) == ["Budget", "Groceries"])
  }

  @Test func emptyStoreReturnsNothing() async throws {
    #expect(try await NoteStore(directory: tempDirectory()).all().isEmpty)
  }

  @Test func notesPersistAcrossStoreInstancesAtTheSameDirectory() async throws {
    let directory = tempDirectory()
    try await NoteStore(directory: directory).save(Note(title: "Persisted", body: "Text."))
    let reopened = try await NoteStore(directory: directory).all()
    #expect(reopened.map(\.title) == ["Persisted"])
  }

  @Test func aFreshDirectoryIsCreatedOnFirstSave() async throws {
    let directory = tempDirectory()
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    try await NoteStore(directory: directory).save(Note(title: "x", body: "y"))
    #expect(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes.json").path))
  }
}

@Suite struct CreateNoteToolTests {
  @Test func propertiesMatchFR008() {
    let tool = CreateNoteTool(store: NoteStore(directory: tempDirectory()))
    #expect(tool.name == "create_note")
    #expect(tool.permission == .userConfirmation)
    #expect(tool.schema.required == ["body", "title"])
  }

  @Test func savesAndReturnsConfirmationText() async throws {
    let store = NoteStore(directory: tempDirectory())
    let tool = CreateNoteTool(store: store)
    let result = try await tool.execute(
      arguments: ToolArguments(["title": "Budget", "body": "Review Tuesday at 3pm."]))
    #expect(result.text == "Saved note \"Budget\".")
    #expect(result.structured != nil)
    let saved = try await store.all()
    #expect(saved.count == 1)
    #expect(saved[0].title == "Budget")
    #expect(saved[0].body == "Review Tuesday at 3pm.")
  }

  @Test func missingTitleIsInvalidArguments() async {
    let tool = CreateNoteTool(store: NoteStore(directory: tempDirectory()))
    await #expect(
      throws: AgentError.invalidArguments(
        tool: "create_note", violations: [.missingRequired(path: "title")])
    ) {
      try await tool.execute(arguments: ToolArguments(["body": "text"]))
    }
  }

  @Test func missingBodyIsInvalidArguments() async {
    let tool = CreateNoteTool(store: NoteStore(directory: tempDirectory()))
    await #expect(
      throws: AgentError.invalidArguments(
        tool: "create_note", violations: [.missingRequired(path: "body")])
    ) {
      try await tool.execute(arguments: ToolArguments(["title": "x"]))
    }
  }

  @Test func emptyTitleOrBodyIsInvalidArguments() async {
    let tool = CreateNoteTool(store: NoteStore(directory: tempDirectory()))
    await #expect(throws: AgentError.self) {
      try await tool.execute(arguments: ToolArguments(["title": "", "body": "text"]))
    }
  }
}
