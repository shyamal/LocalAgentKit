import Foundation

/// A complete text conversation checkpoint, distinct from tool traffic and task working memory.
public struct ConversationSnapshot: Sendable, Hashable {
  /// Stable app-owned identity used to restore the same conversation after relaunch.
  public let conversationID: UUID
  /// Completed user/assistant pairs, optionally preceded by one compacted summary (.system).
  public var messages: [ModelMessage]

  /// Creates a checkpoint value. Storage boundaries validate its completed-turn structure.
  public init(conversationID: UUID, messages: [ModelMessage]) {
    self.conversationID = conversationID
    self.messages = messages
  }

  /// Rejects partial turns, tool calls/results and misplaced summary/instruction entries.
  /// - Throws: `AgentError.memoryFailure` for an invalid transcript shape.
  public func validate() throws {
    let start = messages.first?.role == .system ? 1 : 0
    guard messages.allSatisfy({ $0.toolCalls.isEmpty && $0.toolCallID == nil }),
      (messages.count - start).isMultiple(of: 2)
    else {
      throw AgentError.memoryFailure("Conversation checkpoint must contain completed text turns.")
    }
    for index in stride(from: start, to: messages.count, by: 2) {
      guard messages[index].role == .user, messages[index + 1].role == .assistant else {
        throw AgentError.memoryFailure("Conversation checkpoint must contain completed text turns.")
      }
    }
  }
}

/// Whole-conversation checkpoint storage. Implementations replace one ID atomically, not turn by turn.
/// Framework-specific objects stay inside the provider; callers exchange only value snapshots.
public protocol ConversationStore: Sendable {
  /// True if any operation can require network access; providers must declare this honestly.
  var requiresNetwork: Bool { get }
  /// Loads one conversation, or nil when absent. Corruption is a typed memory failure, not absence.
  func load(conversationID: UUID) async throws -> ConversationSnapshot?
  /// Replaces the complete checkpoint for this identity after validating it.
  func save(_ snapshot: ConversationSnapshot) async throws
  /// Deletes a checkpoint. A missing identity succeeds without mutation.
  func delete(conversationID: UUID) async throws
}

extension ConversationStore {
  /// Default for local-only implementations.
  public var requiresNetwork: Bool { false }
}
