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
  /// Stable rendering of argument values used to distinguish executions.
  /// This is not a hash or redacted value: it can contain sensitive argument text.
  /// Treat exported audit records as sensitive data.
  public var argumentsSignature: String
  /// Whether the result was marked empty despite executing successfully.
  public var wasEmpty: Bool

  /// Creates an execution record with supplied metadata and an optional identity and timestamp.
  public init(
    id: UUID = UUID(), timestamp: Date = Date(), toolName: String, permission: ToolPermission,
    argumentsSignature: String, wasEmpty: Bool
  ) {
    self.id = id
    self.timestamp = timestamp
    self.toolName = toolName
    self.permission = permission
    self.argumentsSignature = argumentsSignature
    self.wasEmpty = wasEmpty
  }
}

/// An append-only local log of sensitive tool executions (FR-022, M1-SE-02): after-the-fact
/// visibility, not prevention — PRD §19 ranks it below the permission gate, which is where
/// execution is actually stopped. In-memory for v0.1; durable persistence is a v0.2 concern, the
/// same deferral `ConversationMemory` makes for its own SwiftData store.
public actor AuditLogger {
  private var entries: [AuditEntry] = []

  /// Creates an empty in-memory audit log.
  public init() {}

  /// There is no corresponding remove: the log is append-only by construction.
  public func record(_ entry: AuditEntry) {
    entries.append(entry)
  }

  /// Returns entries in recording order; no durable persistence is provided.
  public func allEntries() -> [AuditEntry] {
    entries
  }
}
