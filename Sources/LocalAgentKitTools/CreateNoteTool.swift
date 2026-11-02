import Foundation
import LocalAgentKitCore

/// One saved note.
public struct Note: Sendable, Hashable, Identifiable, Codable {
  /// Stable saved-note identity.
  public var id: UUID
  /// Short title shown to the user.
  public var title: String
  /// Full saved text content.
  public var body: String
  /// Timestamp recorded when the note is created.
  public var createdAt: Date

  /// Creates a note with generated identity and current timestamp when omitted.
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

  /// Creates a lazy-loading store at an explicit JSON file URL.
  public init(url: URL) {
    self.url = url
  }

  /// A note store under the given directory (created if needed), named `notes.json`.
  public init(directory: URL) {
    self.url = directory.appendingPathComponent("notes.json")
  }

  /// Appends a note and atomically rewrites the backing JSON file.
  /// Filesystem and encoding errors propagate; the in-memory append is not rolled back on failure.
  public func save(_ note: Note) async throws {
    try load()
    notes.append(note)
    try persist()
  }

  /// Lazily reads and returns stored notes in order.
  /// Missing, unreadable or undecodable files currently yield an empty initial collection.
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
  /// Registered action name `create_note`.
  public let name = "create_note"
  /// Prompt-facing note creation guidance.
  public let description = "Save a new note."
  /// Required title and body text fields.
  public let schema = ToolSchema(
    parameters: [
      "title": ToolParameter(.string, description: "Short title for the note."),
      "body": ToolParameter(.string, description: "The full text of the note."),
    ], required: ["title", "body"])
  /// Requires explicit human approval before writing a note through the runtime.
  public let permission = ToolPermission.userConfirmation
  /// True: the backing actor serializes access to this tool's store.
  public let isParallelSafe = true
  /// Advertises cancellation support to the executor; synchronous file writes cannot be interrupted.
  public let isCancellable = true
  private let store: NoteStore

  /// Creates a tool writing to the supplied app-owned note store.
  public init(store: NoteStore) {
    self.store = store
  }

  /// Validates nonempty title and body, saves a note, and returns its new ID.
  /// Use the runtime for permission enforcement; direct calls write without prompting.
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
