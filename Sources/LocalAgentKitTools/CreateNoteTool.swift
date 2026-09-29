import Foundation
import LocalAgentKitCore

/// One saved note.
public struct Note: Sendable, Hashable, Identifiable, Codable {
  public var id: UUID
  public var title: String
  public var body: String
  public var createdAt: Date

  public init(id: UUID = UUID(), title: String, body: String, createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.body = body
    self.createdAt = createdAt
  }
}

/// A local, file-backed note store — plain Foundation, no framework, since Apple exposes no
/// public API for its own Notes app.
///
/// This is deliberately narrower than FR-008's full Notes capability (M2-09: create *and*
/// search, likely SwiftData-backed to match `MemoryStore`'s other implementations). It exists so
/// the MVP demo's fourth turn ("Save that as a note") has something real to write to; M2-09
/// supersedes it rather than building alongside it.
public actor NoteStore {
  private let url: URL
  private var notes: [Note] = []
  private var loaded = false

  public init(url: URL) {
    self.url = url
  }

  /// A note store under the given directory (created if needed), named `notes.json`.
  public init(directory: URL) {
    self.url = directory.appendingPathComponent("notes.json")
  }

  public func save(_ note: Note) async throws {
    try load()
    notes.append(note)
    try persist()
  }

  public func all() async throws -> [Note] {
    try load()
    return notes
  }

  private func load() throws {
    guard !loaded else { return }
    loaded = true
    guard let data = try? Data(contentsOf: url) else { return }
    notes = (try? JSONDecoder().decode([Note].self, from: data)) ?? []
  }

  private func persist() throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(notes)
    try data.write(to: url, options: .atomic)
  }
}

/// Save a new note (FR-008). `.userConfirmation`: the runtime holds this for a human's yes.
public struct CreateNoteTool: AgentTool {
  public let name = "create_note"
  public let description = "Save a new note."
  public let schema = ToolSchema(
    parameters: [
      "title": ToolParameter(.string, description: "Short title for the note."),
      "body": ToolParameter(.string, description: "The full text of the note."),
    ], required: ["title", "body"])
  public let permission = ToolPermission.userConfirmation
  public let isParallelSafe = true
  public let isCancellable = true
  private let store: NoteStore

  public init(store: NoteStore) {
    self.store = store
  }

  public func execute(arguments: ToolArguments) async throws -> ToolResult {
    guard let title = arguments.string("title"), !title.isEmpty else {
      throw AgentError.invalidArguments(tool: name, violations: [.missingRequired(path: "title")])
    }
    guard let body = arguments.string("body"), !body.isEmpty else {
      throw AgentError.invalidArguments(tool: name, violations: [.missingRequired(path: "body")])
    }
    let note = Note(title: title, body: body)
    try await store.save(note)
    return ToolResult(
      callID: "", toolName: name, text: "Saved note \"\(title)\".",
      structured: .string(note.id.uuidString))
  }
}
