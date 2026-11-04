import Foundation
import LocalAgentKitCore

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
    if Task.isCancelled { throw AgentError.cancelled }
    guard let title = arguments.string("title"),
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AgentError.invalidArguments(tool: name, violations: [.missingRequired(path: "title")])
    }
    guard let body = arguments.string("body"),
      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AgentError.invalidArguments(tool: name, violations: [.missingRequired(path: "body")])
    }
    let note = Note(title: title, body: body)
    try await store.save(note)
    return ToolResult(
      callID: "", toolName: name, text: "Saved note \"\(title)\".",
      structured: .string(note.id.uuidString))
  }
}
