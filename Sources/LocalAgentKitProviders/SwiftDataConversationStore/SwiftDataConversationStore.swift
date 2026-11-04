import Foundation
import LocalAgentKitCore
import SwiftData

/// Local, whole-conversation checkpoints with CloudKit disabled and a private serial model actor.
/// Use a dedicated file URL: this schema must not share the SwiftDataMemoryStore data file.
public struct SwiftDataConversationStore: ConversationStore {
  /// Uses the same explicit transient/file placement choices as local text memory.
  public typealias Storage = SwiftDataMemoryStore.Storage
  private let database: ConversationDatabase

  /// Opens checkpoint storage. File placement must be app-owned and separate from other schemas.
  /// - Throws: `AgentError.memoryFailure` on invalid URLs or initialization failure.
  public init(storage: Storage) throws {
    do {
      let schema = Schema(versionedSchema: ConversationSchemaV1.self)
      let configuration: ModelConfiguration
      switch storage {
      case .inMemory:
        configuration = ModelConfiguration(
          schema: schema, isStoredInMemoryOnly: true,
          groupContainer: .none, cloudKitDatabase: .none)
      case .file(let url):
        guard url.isFileURL else {
          throw AgentError.memoryFailure("Storage URL must be a file URL.")
        }
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StoreCompatibility.validate(url, schemas: ConversationMigrationPlan.schemas)
        configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
      }
      database = ConversationDatabase(
        container: try ModelContainer(
          for: schema, migrationPlan: ConversationMigrationPlan.self,
          configurations: [configuration]))
    } catch let error as AgentError { throw error } catch {
      throw AgentError.memoryFailure(
        "Could not open conversation storage: \(error.localizedDescription)")
    }
  }

  /// Loads one validated checkpoint or nil if absent. Unknown formats and corrupt data throw.
  public func load(conversationID: UUID) async throws -> ConversationSnapshot? {
    try await database.load(conversationID)
  }

  /// Atomically replaces a completed-text checkpoint. Pending changes roll back on failure.
  /// Cancellation is checked before work and commit; a synchronous save cannot be interrupted.
  public func save(_ snapshot: ConversationSnapshot) async throws {
    try await database.save(snapshot)
  }

  /// Deletes one checkpoint; absent IDs succeed without a write.
  public func delete(conversationID: UUID) async throws {
    try await database.delete(conversationID)
  }
}

// This is a separate schema/file from general Memory records; neither format is silently mixed.
enum ConversationSchemaV1: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
  static var models: [any PersistentModel.Type] { [StoredConversation.self] }
  @Model final class StoredConversation {
    @Attribute(.unique) var id: UUID
    var payload: Data
    init(id: UUID, payload: Data) {
      self.id = id
      self.payload = payload
    }
  }
}

private struct ConversationEnvelope: Codable {
  struct Entry: Codable {
    var role: String
    var content: String
  }
  var version: Int
  var conversationID: UUID
  var entries: [Entry]

  static func encode(_ snapshot: ConversationSnapshot) throws -> Data {
    try snapshot.validate()
    let entries = try snapshot.messages.map { message -> Entry in
      let role: String
      switch message.role {
      case .system: role = "summary"
      case .user: role = "user"
      case .assistant: role = "assistant"
      case .tool: throw AgentError.memoryFailure("Tool traffic cannot be checkpointed.")
      }
      return Entry(role: role, content: message.content)
    }
    return try JSONEncoder().encode(
      Self(version: 1, conversationID: snapshot.conversationID, entries: entries))
  }

  static func decode(_ data: Data, expectedID: UUID) throws -> ConversationSnapshot {
    let envelope = try JSONDecoder().decode(Self.self, from: data)
    guard envelope.version == 1 else {
      throw AgentError.memoryFailure("Unsupported conversation checkpoint format.")
    }
    guard envelope.conversationID == expectedID else {
      throw AgentError.memoryFailure("Conversation checkpoint identity mismatch.")
    }
    let messages = try envelope.entries.map { entry -> ModelMessage in
      let role: ModelMessage.Role
      switch entry.role {
      case "summary": role = .system
      case "user": role = .user
      case "assistant": role = .assistant
      default: throw AgentError.memoryFailure("Unsupported conversation checkpoint role.")
      }
      return ModelMessage(role: role, content: entry.content)
    }
    let snapshot = ConversationSnapshot(conversationID: expectedID, messages: messages)
    try snapshot.validate()
    return snapshot
  }
}

@ModelActor private actor ConversationDatabase {
  private typealias Record = ConversationSchemaV1.StoredConversation
  init(container: ModelContainer) {
    let context = ModelContext(container)
    context.autosaveEnabled = false
    modelContainer = container
    modelExecutor = DefaultSerialModelExecutor(modelContext: context)
  }

  func load(_ id: UUID) throws -> ConversationSnapshot? {
    try checkCancellation()
    do {
      guard let record = try find(id) else { return nil }
      let result = try ConversationEnvelope.decode(record.payload, expectedID: id)
      try checkCancellation()
      return result
    } catch { throw mapped(error) }
  }

  func save(_ snapshot: ConversationSnapshot) throws {
    try checkCancellation()
    do {
      let payload = try ConversationEnvelope.encode(snapshot)
      if let record = try find(snapshot.conversationID) {
        record.payload = payload
      } else {
        modelContext.insert(Record(id: snapshot.conversationID, payload: payload))
      }
      try checkCancellation()
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw mapped(error)
    }
  }

  func delete(_ id: UUID) throws {
    try checkCancellation()
    do {
      guard let record = try find(id) else { return }
      modelContext.delete(record)
      try checkCancellation()
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw mapped(error)
    }
  }

  private func find(_ id: UUID) throws -> Record? {
    var descriptor = FetchDescriptor<Record>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }
  private func checkCancellation() throws { if Task.isCancelled { throw AgentError.cancelled } }
  private func mapped(_ error: any Error) -> AgentError {
    if let error = error as? AgentError { return error }
    if error is CancellationError { return .cancelled }
    return .memoryFailure("Conversation storage operation failed: \(error.localizedDescription)")
  }
}
