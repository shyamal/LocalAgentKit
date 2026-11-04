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

/// App-owned local notes, retaining the demo's original JSON array format and file location.
/// Share one instance per file; independent instances/process writers are not coordinated.
/// Corrupt/unreadable data fails closed instead of being replaced by an empty collection.
public actor NoteStore {
  private let url: URL
  private var notes: [Note] = []
  private var loaded = false

  /// Creates a lazy-loading store at an explicit local file URL; operations reject non-file URLs.
  public init(url: URL) { self.url = url }

  /// Stores notes in notes.json under the supplied directory, created on the first save.
  public init(directory: URL) { self.url = directory.appendingPathComponent("notes.json") }

  /// Appends a note, atomically writes the JSON array, then updates the in-memory collection.
  /// Failed writes leave the cached notes unchanged. Cancellation is checked before work/commit;
  /// a synchronous file write already in progress cannot be interrupted or rolled back.
  /// - Throws: Typed memory failures for storage/encoding problems, or cancellation.
  public func save(_ note: Note) async throws {
    try checkCancellation()
    try load()
    let candidate = notes + [note]
    do {
      let data = try JSONEncoder().encode(candidate)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try checkCancellation()
      try data.write(to: url, options: .atomic)
      notes = candidate
    } catch { throw mapped(error, operation: "save") }
  }

  /// Returns notes in insertion order, loading lazily. Only a missing file is treated as empty.
  /// - Throws: Typed memory failures for unreadable/corrupt storage, or cancellation.
  public func all() async throws -> [Note] {
    try checkCancellation()
    try load()
    return notes
  }

  /// Searches title/body using localized case/diacritic-insensitive substring matching.
  /// Empty text matches all; non-positive limits return none. Results are newest first, with
  /// UUID string ascending for equal dates. Matching reads the small JSON store, not an index.
  /// - Throws: Typed memory failures or cancellation; the store is never modified by a search.
  public func search(query: String, limit: Int = 5) async throws -> [Note] {
    try checkCancellation()
    guard limit > 0 else { return [] }
    try load()
    let matches = notes.filter {
      query.isEmpty || $0.title.localizedStandardContains(query)
        || $0.body.localizedStandardContains(query)
    }
    try checkCancellation()
    return Array(
      matches.sorted {
        $0.createdAt == $1.createdAt
          ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
      }.prefix(limit))
  }

  private func load() throws {
    guard url.isFileURL else {
      throw AgentError.memoryFailure("Note storage URL must be a file URL.")
    }
    guard !loaded else { return }
    do {
      let data = try Data(contentsOf: url)
      let decoded = try JSONDecoder().decode([Note].self, from: data)
      try checkCancellation()
      notes = decoded
      loaded = true
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      notes = []
      loaded = true
    } catch { throw mapped(error, operation: "load") }
  }

  private func checkCancellation() throws {
    if Task.isCancelled { throw AgentError.cancelled }
  }

  private func mapped(_ error: any Error, operation: String) -> AgentError {
    if let error = error as? AgentError { return error }
    if error is CancellationError { return .cancelled }
    return .memoryFailure("Could not \(operation) local notes: \(error.localizedDescription)")
  }
}
