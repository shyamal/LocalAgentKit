import Foundation

public struct Memory: Sendable, Hashable, Identifiable, Codable {
  public var id: UUID
  public var content: String
  public var createdAt: Date
  public var metadata: [String: String]

  public init(
    id: UUID = UUID(), content: String, createdAt: Date = Date(), metadata: [String: String] = [:]
  ) {
    self.id = id
    self.content = content
    self.createdAt = createdAt
    self.metadata = metadata
  }
}

public struct MemoryQuery: Sendable, Hashable {
  public var text: String
  public var limit: Int

  public init(text: String, limit: Int = 5) {
    self.text = text
    self.limit = limit
  }
}

/// Persistent agent memory (FR-012). The SwiftData implementation lands in v0.2.
public protocol MemoryStore: Sendable {
  func save(_ memory: Memory) async throws
  func search(_ query: MemoryQuery) async throws -> [Memory]
  func delete(id: UUID) async throws
}
