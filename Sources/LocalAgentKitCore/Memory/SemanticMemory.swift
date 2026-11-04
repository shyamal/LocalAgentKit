import Foundation

/// An explicitly saved durable fact or preference (FR-011), stored through MemoryStore.
/// This category describes retained knowledge; it does not imply embedding/vector search.
public struct SemanticMemory: Sendable, Hashable, Identifiable {
  /// The meaning of the retained statement; chosen by the app, never inferred automatically.
  public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
    /// A durable statement about the user or their world.
    case fact
    /// A user preference, such as a desired answer style.
    case preference
  }

  /// Stable identity used to replace or delete this statement.
  public var id: UUID
  /// Whether this statement is a fact or a preference.
  public var kind: Kind
  /// The retained statement, which must contain non-whitespace text when saved.
  public var content: String
  /// App-owned creation timestamp, preserved when updating unless explicitly changed.
  public var createdAt: Date
  /// App-defined attributes. The three LocalAgentKit encoding keys are reserved.
  public var metadata: [String: String]

  static let categoryKey = "localagentkit.memory.category"
  static let kindKey = "localagentkit.semantic.kind"
  static let versionKey = "localagentkit.semantic.version"

  /// Creates a statement. Validation occurs when encoding or saving it.
  /// Reuse the same ID to replace an existing statement; text equality does not deduplicate.
  public init(
    id: UUID = UUID(), kind: Kind, content: String, createdAt: Date = Date(),
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.content = content
    self.createdAt = createdAt
    self.metadata = metadata
  }

  /// Encodes this value as an ordinary Memory with versioned, namespaced category metadata.
  /// - Throws: `AgentError.memoryFailure` for blank content or app use of reserved keys.
  public func memory() throws -> Memory {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentError.memoryFailure("Semantic memory content must not be blank.")
    }
    guard [Self.categoryKey, Self.kindKey, Self.versionKey].allSatisfy({ metadata[$0] == nil })
    else {
      throw AgentError.memoryFailure("Semantic memory metadata uses a reserved key.")
    }
    var attributes = metadata
    attributes[Self.categoryKey] = "semantic"
    attributes[Self.kindKey] = kind.rawValue
    attributes[Self.versionKey] = "1"
    return Memory(id: id, content: content, createdAt: createdAt, metadata: attributes)
  }

  /// Decodes a semantic record, rejecting other categories, unsupported versions and invalid data.
  /// App-defined metadata is preserved; internal encoding keys are removed from the typed value.
  /// - Throws: `AgentError.memoryFailure` if this is not a valid version-one semantic record.
  public init(memory: Memory) throws {
    guard memory.metadata[Self.categoryKey] == "semantic",
      memory.metadata[Self.versionKey] == "1",
      let kind = memory.metadata[Self.kindKey].flatMap(Kind.init(rawValue:))
    else {
      throw AgentError.memoryFailure("Invalid or unsupported semantic memory record.")
    }
    var attributes = memory.metadata
    for key in [Self.categoryKey, Self.kindKey, Self.versionKey] {
      attributes.removeValue(forKey: key)
    }
    self.init(
      id: memory.id, kind: kind, content: memory.content, createdAt: memory.createdAt,
      metadata: attributes)
    _ = try self.memory()
  }
}

extension MemoryStore {
  /// Explicitly saves a fact or preference through the existing store; no model call is made.
  /// Apps must obtain any required user consent before calling this host API. It does not expose
  /// an agent tool or bypass a tool permission gate. Failures and cancellation are propagated.
  public func save(_ semanticMemory: SemanticMemory) async throws {
    if Task.isCancelled { throw AgentError.cancelled }
    try await save(semanticMemory.memory())
  }

  /// Searches only semantic records, optionally restricted to facts or preferences.
  /// Category/kind constraints apply before the limit. Text matching and ordering follow the store.
  /// Invalid matched records fail with a typed memory error rather than being silently skipped.
  /// Automatic retrieval into model prompts is separate; this method does not change runtime state.
  public func searchSemantic(
    text: String, kind: SemanticMemory.Kind? = nil, limit: Int = 5
  ) async throws -> [SemanticMemory] {
    if Task.isCancelled { throw AgentError.cancelled }
    guard limit > 0 else { return [] }
    var metadata = [SemanticMemory.categoryKey: "semantic"]
    if let kind { metadata[SemanticMemory.kindKey] = kind.rawValue }
    let records = try await search(MemoryQuery(text: text, limit: limit, metadata: metadata))
    if Task.isCancelled { throw AgentError.cancelled }
    return try records.map { try SemanticMemory(memory: $0) }
  }
}
