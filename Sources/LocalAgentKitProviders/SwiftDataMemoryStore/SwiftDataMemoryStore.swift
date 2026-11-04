import Foundation
import LocalAgentKitCore
import SwiftData

/// Local SwiftData-backed text memory. One actor owns its context; model objects never escape.
/// CloudKit is disabled and storage placement is explicit. Runtime context retrieval remains separate (M2-07).
public struct SwiftDataMemoryStore: MemoryStore {
  /// Explicitly chooses transient storage or an app-owned persistent file.
  public enum Storage: Sendable {
    /// An isolated store whose contents disappear when its container is released.
    case inMemory
    /// A local file URL; the parent directory is created if necessary.
    case file(URL)
  }

  private let database: MemoryDatabase

  /// Opens a local store with explicit storage placement and automatic saving disabled.
  /// - Throws: `AgentError.memoryFailure` if the location is invalid or initialization fails.
  public init(storage: Storage) throws {
    do {
      let schema = Schema(versionedSchema: MemorySchemaV1.self)
      let configuration: ModelConfiguration
      switch storage {
      case .inMemory:
        configuration = ModelConfiguration(
          schema: schema, isStoredInMemoryOnly: true, groupContainer: .none, cloudKitDatabase: .none
        )
      case .file(let url):
        guard url.isFileURL else {
          throw AgentError.memoryFailure("Storage URL must be a file URL.")
        }
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
      }
      let container = try ModelContainer(for: schema, configurations: [configuration])
      self.database = MemoryDatabase(container: container)
    } catch let error as AgentError {
      throw error
    } catch {
      throw AgentError.memoryFailure(
        "Could not open local memory storage: \(error.localizedDescription)")
    }
  }

  /// Inserts or replaces every field for an existing ID and explicitly commits the change.
  /// Failed or cancelled mutations roll back pending changes in the private model context.
  /// Cancellation is checked before work and commit; a synchronous commit cannot be interrupted.
  public func save(_ memory: Memory) async throws {
    try await database.save(memory)
  }

  /// Finds localized case/diacritic-insensitive content substrings, newest first.
  /// Empty text matches all memories. Ties use UUID string ascending; non-positive limits
  /// return no results. Metadata is not searched. Matching rows are materialized in memory
  /// before sorting and limiting; this is a small-store implementation, not full-text search.
  /// - Throws: Typed memory errors (including corrupt returned metadata) or cancellation.
  public func search(_ query: MemoryQuery) async throws -> [Memory] {
    try await database.search(query)
  }

  /// Deletes and commits a matching memory; an unknown ID succeeds without mutation.
  public func delete(id: UUID) async throws {
    try await database.delete(id: id)
  }
}

// The framework's serial model executor keeps context access on its owning queue, including
// when an app constructs the public wrapper on MainActor and then calls it from other tasks.
@ModelActor
private actor MemoryDatabase {
  private typealias Record = MemorySchemaV1.StoredMemory
  private var context: ModelContext { modelContext }

  init(container: ModelContainer) {
    let context = ModelContext(container)
    context.autosaveEnabled = false
    self.modelContainer = container
    self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
  }

  /// Inserts a memory or replaces all fields of the memory with the same ID, then saves.
  /// A failed or cancelled mutation rolls back this context's pending changes.
  func save(_ memory: Memory) async throws {
    try checkCancellation()
    do {
      let replacement = try Record(memory: memory)
      if let record = try find(memory.id) {
        record.content = replacement.content
        record.createdAt = replacement.createdAt
        record.metadataJSON = replacement.metadataJSON
      } else {
        context.insert(replacement)
      }
      try checkCancellation()
      try context.save()
    } catch {
      context.rollback()
      throw mapped(error, operation: "save")
    }
  }

  /// Finds localized case/diacritic-insensitive content substrings, newest first.
  /// Empty text matches all memories. Equal timestamps are ordered by UUID string ascending.
  /// Limits of zero or less return no results; metadata is not searched.
  /// - Throws: Typed memory errors, including corrupt metadata in a returned record, or cancellation.
  func search(_ query: MemoryQuery) async throws -> [Memory] {
    try checkCancellation()
    guard query.limit > 0 else { return [] }
    do {
      let needle = query.text
      let predicate: Predicate<Record>? =
        needle.isEmpty
        ? nil
        : #Predicate<Record> {
          $0.content.localizedStandardContains(needle)
        }
      // Sort ties in Swift because UUID ordering is part of this provider's contract.
      let records = try context.fetch(FetchDescriptor<Record>(predicate: predicate))
      try checkCancellation()
      let ordered = records.sorted {
        $0.createdAt == $1.createdAt
          ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
      }
      return try ordered.prefix(query.limit).map { try $0.memory() }
    } catch {
      throw mapped(error, operation: "search")
    }
  }

  /// Deletes and saves a matching memory; deleting an unknown ID succeeds without mutation.
  func delete(id: UUID) async throws {
    try checkCancellation()
    do {
      guard let record = try find(id) else { return }
      context.delete(record)
      try checkCancellation()
      try context.save()
    } catch {
      context.rollback()
      throw mapped(error, operation: "delete")
    }
  }

  private func find(_ id: UUID) throws -> Record? {
    var descriptor = FetchDescriptor<Record>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private func checkCancellation() throws {
    if Task.isCancelled { throw AgentError.cancelled }
  }

  private func mapped(_ error: any Error, operation: String) -> AgentError {
    if let error = error as? AgentError { return error }
    if error is CancellationError { return .cancelled }
    return .memoryFailure("Could not \(operation) local memory: \(error.localizedDescription)")
  }
}
