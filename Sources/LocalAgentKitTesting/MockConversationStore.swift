import Foundation
import LocalAgentKitCore

/// An in-memory checkpoint store for asset-free conversation persistence tests.
public actor MockConversationStore: ConversationStore {
  /// Explicit network declaration used to test persistence policy checks.
  public nonisolated let requiresNetwork: Bool
  /// Latest snapshots keyed by conversation identity.
  public private(set) var snapshots: [UUID: ConversationSnapshot] = [:]

  /// Creates an empty store; no real networking occurs even when the declaration is true.
  public init(requiresNetwork: Bool = false) { self.requiresNetwork = requiresNetwork }

  /// Returns a previously saved checkpoint or nil.
  public func load(conversationID: UUID) async throws -> ConversationSnapshot? {
    if Task.isCancelled { throw AgentError.cancelled }
    return snapshots[conversationID]
  }

  /// Validates and replaces the checkpoint for one identity.
  public func save(_ snapshot: ConversationSnapshot) async throws {
    if Task.isCancelled { throw AgentError.cancelled }
    try snapshot.validate()
    snapshots[snapshot.conversationID] = snapshot
  }

  /// Removes one checkpoint; absent identities do nothing.
  public func delete(conversationID: UUID) async throws {
    if Task.isCancelled { throw AgentError.cancelled }
    snapshots[conversationID] = nil
  }
}
