import Foundation
import LocalAgentKitCore

/// One recorded sensitive tool execution (FR-022): a record that it ran, not what it returned —
/// a tool's full result could itself be the sensitive content.
public struct AuditEntry: Sendable, Hashable, Identifiable {
  public var id: UUID
  public var timestamp: Date
  public var toolName: String
  public var permission: ToolPermission
  /// The same de-ordered rendering `LoopDetector` uses to tell calls apart — enough to
  /// distinguish two executions, not a copy of potentially sensitive argument values.
  public var argumentsSignature: String
  public var wasEmpty: Bool

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

  public init() {}

  /// There is no corresponding remove: the log is append-only by construction.
  public func record(_ entry: AuditEntry) {
    entries.append(entry)
  }

  public func allEntries() -> [AuditEntry] {
    entries
  }
}
