import Foundation
import LocalAgentKitCore

/// One recorded sensitive tool execution (FR-022): a record that it ran, not what it returned —
/// a tool's full result could itself be the sensitive content.
public struct AuditEntry: Sendable, Hashable, Identifiable {
  /// Unique audit-record identity.
  public var id: UUID
  /// Time the execution was recorded.
  public var timestamp: Date
  /// Registered name of the tool that executed.
  public var toolName: String
  /// Confirmation tier advertised by the tool.
  public var permission: ToolPermission
  /// Rendering of argument values used to distinguish executions, possibly capped by retention.
  /// This is not a hash or redacted value: it can contain sensitive argument text.
  /// Treat exported audit records as sensitive data.
  public var argumentsSignature: String
  /// True when retained argument text is incomplete, including truncation by the logger.
  public var argumentsWereTruncated: Bool
  /// Whether the result was marked empty despite executing successfully.
  public var wasEmpty: Bool

  /// Creates an execution record with supplied metadata and an optional identity and timestamp.
  public init(
    id: UUID = UUID(), timestamp: Date = Date(), toolName: String, permission: ToolPermission,
    argumentsSignature: String, wasEmpty: Bool, argumentsWereTruncated: Bool = false
  ) {
    self.id = id
    self.timestamp = timestamp
    self.toolName = toolName
    self.permission = permission
    self.argumentsSignature = argumentsSignature
    self.argumentsWereTruncated = argumentsWereTruncated
    self.wasEmpty = wasEmpty
  }
}

/// Session-only bounds for a local audit window. This is not a durable retention-period policy.
public struct AuditRetentionPolicy: Sendable, Hashable, Encodable {
  /// Maximum newest records retained in recording order, clamped to at least one.
  public let maximumEntries: Int
  /// Maximum grapheme characters of each argument signature retained, clamped to at least one.
  public let maximumSignatureCharacters: Int

  /// Creates count/size bounds; invalid non-positive values are clamped to one.
  public init(maximumEntries: Int = 1000, maximumSignatureCharacters: Int = 4096) {
    self.maximumEntries = max(1, maximumEntries)
    self.maximumSignatureCharacters = max(1, maximumSignatureCharacters)
  }

  /// Retains at most 1,000 records with 4,096 characters per signature for this logger's lifetime.
  public static let `default` = AuditRetentionPolicy()
}

/// A bounded, session-only local audit trail for confirmed successful sensitive executions.
/// Records are appended in order within a retained window; old records are evicted by policy.
/// No automatic disk persistence, export destination or network transmission is provided.
/// This diagnostic trail is not tamper-evident or a complete history of attempts/side effects.
public actor AuditLogger {
  /// Immutable bounds selected by the host. Argument signatures remain sensitive in memory.
  public nonisolated let retention: AuditRetentionPolicy
  /// Records discarded through capacity eviction or explicit clearing during this logger's life.
  public private(set) var discardedEntryCount = 0
  private var entries: [AuditEntry] = []

  /// Creates an empty in-memory log. The default now bounds the previously unbounded v0.1 log.
  public init(retention: AuditRetentionPolicy = .default) { self.retention = retention }

  /// Appends a value snapshot, caps its signature and evicts oldest recordings above capacity.
  /// Recording is nonthrowing and performs no I/O, so a tool's successful action is not reversed
  /// or reported failed because audit persistence is unavailable.
  public func record(_ entry: AuditEntry) {
    var retained = entry
    let signature = entry.argumentsSignature.prefix(retention.maximumSignatureCharacters)
    retained.argumentsWereTruncated =
      entry.argumentsWereTruncated || signature.endIndex != entry.argumentsSignature.endIndex
    retained.argumentsSignature = String(signature)
    entries.append(retained)
    let excess = entries.count - retention.maximumEntries
    if excess > 0 {
      entries.removeFirst(excess)
      discardedEntryCount += excess
    }
  }

  /// Returns retained entries in recording order, not timestamp order. Returned copies are independent.
  public func allEntries() -> [AuditEntry] { entries }

  /// Explicit host-owned deletion of this in-memory window; exported copies are not affected.
  /// Clearing retains the discard counter so later exports do not imply a complete history.
  public func clear() {
    discardedEntryCount += entries.count
    entries.removeAll(keepingCapacity: false)
  }

  /// Encodes a version-one JSON snapshot. Arguments (and their truncation flags) are omitted
  /// unless explicitly included; metadata itself may still identify people or activities.
  /// Dates are numeric milliseconds since Unix epoch. This method never writes or sends the data.
  /// - Throws: memoryFailure if a timestamp or other value cannot be encoded as JSON.
  public func exportJSON(includeArguments: Bool = false, exportedAt: Date = Date()) throws -> Data {
    try AuditJSON.encode(
      entries: entries, retention: retention, discardedEntryCount: discardedEntryCount,
      includeArguments: includeArguments, exportedAt: exportedAt)
  }
}
