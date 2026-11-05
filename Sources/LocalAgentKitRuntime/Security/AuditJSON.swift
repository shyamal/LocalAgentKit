import Foundation
import LocalAgentKitCore

/// Version-one wire format is separate from the mutable runtime entry representation.
enum AuditJSON {
  private struct Snapshot: Encodable {
    let schemaVersion = 1
    var exportedAt: Date
    var includesArguments: Bool
    var retention: AuditRetentionPolicy
    var discardedEntryCount: Int
    var entries: [Record]
  }
  private struct Record: Encodable {
    var id: UUID
    var timestamp: Date
    var toolName: String
    var permission: String
    var wasEmpty: Bool
    var argumentsSignature: String?
    var argumentsWereTruncated: Bool?
  }

  static func encode(
    entries: [AuditEntry], retention: AuditRetentionPolicy, discardedEntryCount: Int,
    includeArguments: Bool, exportedAt: Date
  ) throws -> Data {
    let snapshot = Snapshot(
      exportedAt: exportedAt, includesArguments: includeArguments, retention: retention,
      discardedEntryCount: discardedEntryCount,
      entries: entries.map { entry in
        Record(
          id: entry.id, timestamp: entry.timestamp, toolName: entry.toolName,
          permission: label(entry.permission), wasEmpty: entry.wasEmpty,
          argumentsSignature: includeArguments ? entry.argumentsSignature : nil,
          argumentsWereTruncated: includeArguments ? entry.argumentsWereTruncated : nil)
      })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    do { return try encoder.encode(snapshot) } catch {
      throw AgentError.memoryFailure("Could not encode audit export.")
    }
  }

  private static func label(_ permission: ToolPermission) -> String {
    switch permission {
    case .none: "none"
    case .readOnly: "readOnly"
    case .userConfirmation: "userConfirmation"
    case .sensitive: "sensitive"
    case .destructive: "destructive"
    }
  }
}
