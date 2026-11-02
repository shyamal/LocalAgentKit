import Foundation

/// A persistable text memory with identity, timestamp and app-defined metadata.
public struct Memory: Sendable, Hashable, Identifiable, Codable {
  /// Stable identity used to update or delete a memory.
  public var id: UUID
  /// Text retained for later search.
  public var content: String
  /// Creation timestamp supplied by the host or defaulted to now.
  public var createdAt: Date
  /// App-defined string attributes associated with the memory.
  public var metadata: [String: String]

  /// Creates a memory, generating an identity and timestamp when omitted.
  public init(
    id: UUID = UUID(), content: String, createdAt: Date = Date(), metadata: [String: String] = [:]
  ) {
    self.id = id
    self.content = content
    self.createdAt = createdAt
    self.metadata = metadata
  }
}

/// A text query and result limit for a memory-store search.
public struct MemoryQuery: Sendable, Hashable {
  /// Text the store uses to find relevant memories.
  public var text: String
  /// Maximum number of results requested; use a non-negative value.
  public var limit: Int

  /// Creates a memory query, requesting at most five results by default.
  public init(text: String, limit: Int = 5) {
    self.text = text
    self.limit = limit
  }
}

/// Persistent agent memory (FR-012). The SwiftData implementation lands in v0.2.
public protocol MemoryStore: Sendable {
  /// Persists a memory; implementations define replacement behavior for existing IDs.
  /// Throw a typed memory failure when persistence cannot complete.
  func save(_ memory: Memory) async throws
  /// Returns memories matching the query within its requested limit.
  /// Matching and ordering are implementation-specific; failures should be typed memory errors.
  func search(_ query: MemoryQuery) async throws -> [Memory]
  /// Deletes the memory identified by `id`; implementations define missing-ID behavior.
  func delete(id: UUID) async throws
}
