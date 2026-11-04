import SwiftData

/// Conversation checkpoints use their own file and version history, independent of text memory.
/// Append released versions and adjacent upgrade stages; never rewrite a released schema.
/// The version inside each JSON checkpoint payload is a separate compatibility boundary.
enum ConversationMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [ConversationSchemaV1.self] }
  static var stages: [MigrationStage] { [] }
}
