import SwiftData

/// Released schemas are immutable. Append each supported version and its adjacent upgrade
/// stage here when the storage shape changes; semantic metadata versions are separate.
/// Only V1 is shipped today, so there is no migration stage or artificial V2 schema.
enum MemoryMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [MemorySchemaV1.self] }
  static var stages: [MigrationStage] { [] }
}
