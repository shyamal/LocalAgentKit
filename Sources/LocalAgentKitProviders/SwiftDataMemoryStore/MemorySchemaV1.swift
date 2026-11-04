import Foundation
import LocalAgentKitCore
import SwiftData

/// Initial on-disk representation. Keep released versions immutable; future changes belong
/// in a new VersionedSchema and the migration plan (M2-08).
enum MemorySchemaV1: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
  static var models: [any PersistentModel.Type] { [StoredMemory.self] }

  /// Framework objects remain inside Providers; only Core Memory values cross the store seam.
  @Model final class StoredMemory {
    @Attribute(.unique) var id: UUID
    var content: String
    var createdAt: Date
    // JSON data avoids a framework-specific dictionary transformer on disk. Metadata remains
    // app-defined: category/session semantics are introduced by later memory tasks.
    var metadataJSON: Data

    init(memory: Memory) throws {
      self.id = memory.id
      self.content = memory.content
      self.createdAt = memory.createdAt
      do {
        self.metadataJSON = try JSONEncoder().encode(memory.metadata)
      } catch {
        throw AgentError.memoryFailure("Could not encode stored memory metadata.")
      }
    }

    func memory() throws -> Memory {
      let metadata: [String: String]
      do {
        metadata = try JSONDecoder().decode([String: String].self, from: metadataJSON)
      } catch {
        throw AgentError.memoryFailure("Could not decode stored memory metadata.")
      }
      return Memory(id: id, content: content, createdAt: createdAt, metadata: metadata)
    }
  }
}
