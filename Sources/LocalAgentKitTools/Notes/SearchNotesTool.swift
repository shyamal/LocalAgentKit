import Foundation
import LocalAgentKitCore

/// Read-only search of notes saved in the app's NoteStore (FR-008), without an embedding model.
public struct SearchNotesTool: AgentTool {
  /// Registered read action name.
  public let name = "search_notes"
  /// Model-facing guidance distinguishing saved app notes from indexed external documents.
  public let description =
    "Search this app's saved local notes by a word or phrase in the title or body. "
    + "Returns matching note previews, not indexed documents or Apple Notes."
  /// Requires query text; execution also rejects whitespace-only values.
  public let schema = ToolSchema(
    parameters: [
      "query": ToolParameter(.string, description: "Word or phrase to find in saved notes.")
    ],
    required: ["query"])
  /// Reads app-owned notes without mutation or a destination/exfiltration argument.
  public let permission = ToolPermission.readOnly
  /// The shared store actor serializes concurrent reads and creates.
  public let isParallelSafe = true
  /// Checks cancellation before/after store access; synchronous filesystem reads are not interruptible.
  public let isCancellable = true
  private let store: NoteStore
  private let limit: Int

  /// Searches the supplied app-owned store, clamping previews per call to 1...10.
  public init(store: NoteStore, limit: Int = 5) {
    self.store = store
    self.limit = min(10, max(1, limit))
  }

  /// Returns bounded title/body previews and IDs, or an explicit empty result. Storage errors
  /// propagate instead of being disguised as no matches. Full note contents stay in the store.
  public func execute(arguments: ToolArguments) async throws -> ToolResult {
    if Task.isCancelled { throw AgentError.cancelled }
    guard let query = arguments.string("query"),
      !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AgentError.invalidArguments(tool: name, violations: [.missingRequired(path: "query")])
    }
    let notes = try await store.search(query: query, limit: limit)
    if Task.isCancelled { throw AgentError.cancelled }
    guard !notes.isEmpty else {
      return ToolResult(callID: "", toolName: name, text: "No saved notes found.", isEmpty: true)
    }
    let previews = notes.map { note in
      (
        id: note.id.uuidString, title: Self.clip(note.title, 120),
        snippet: Self.clip(note.body, 400)
      )
    }
    return ToolResult(
      callID: "", toolName: name,
      text: previews.enumerated().map {
        "[\($0.offset + 1)] \($0.element.title): \($0.element.snippet)"
      }
      .joined(separator: "\n\n"),
      structured: .array(
        previews.map {
          .object([
            "id": .string($0.id), "title": .string($0.title), "snippet": .string($0.snippet),
          ])
        }))
  }

  private static func clip(_ text: String, _ limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit)) + "…" : text
  }
}

/// The Notes capability uses separate tools so search never inherits write authority.
public enum NotesTool {
  /// Registers create_note (.userConfirmation) and search_notes (.readOnly) over the same store.
  /// Pass this array to a ToolSource; tools do not register themselves or prompt on direct calls.
  public static func tools(store: NoteStore) -> [any AgentTool] {
    [CreateNoteTool(store: store), SearchNotesTool(store: store)]
  }
}
