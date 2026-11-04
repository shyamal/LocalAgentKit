import Foundation

/// An explicitly retained past event or action (FR-011), persisted through MemoryStore.
/// Recording an episode does not execute an action or grant permission to repeat it.
public struct EpisodicMemory: Sendable, Hashable, Identifiable {
  /// The app-selected meaning of the retained episode.
  public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Something that happened, such as a completed meeting.
    case event
    /// An action that was taken, such as saving a preparation note.
    case action
  }

  /// Stable identity used to replace or delete the episode.
  public var id: UUID
  /// Whether the episode describes an event or an action.
  public var kind: Kind
  /// A non-blank description supplied by the host, not extracted automatically.
  public var content: String
  /// When the event or action occurred, independently of when the memory was created.
  public var occurredAt: Date
  /// When the memory was recorded. Store ordering uses this date, not occurredAt.
  public var createdAt: Date
  /// App-defined attributes; the four LocalAgentKit encoding keys are reserved.
  public var metadata: [String: String]

  static let categoryKey = "localagentkit.memory.category"
  static let kindKey = "localagentkit.episodic.kind"
  static let versionKey = "localagentkit.episodic.version"
  static let occurrenceKey = "localagentkit.episodic.occurredAt"
  private static let reservedKeys = [categoryKey, kindKey, versionKey, occurrenceKey]

  /// Creates an episode with an explicit occurrence date. Validation occurs when encoding/saving.
  /// Reuse an ID to correct an existing episode; identical text does not imply duplicate identity.
  public init(
    id: UUID = UUID(), kind: Kind, content: String, occurredAt: Date,
    createdAt: Date = Date(), metadata: [String: String] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.content = content
    self.occurredAt = occurredAt
    self.createdAt = createdAt
    self.metadata = metadata
  }

  /// Encodes an ordinary Memory using versioned category metadata, without changing store schemas.
  /// The occurrence date uses finite seconds since Foundation's 2001 UTC reference date so its
  /// floating-point precision round-trips without a calendar/string-format conversion.
  /// - Throws: `AgentError.memoryFailure` for blank text, non-finite dates or reserved app keys.
  public func memory() throws -> Memory {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentError.memoryFailure("Episodic memory content must not be blank.")
    }
    guard occurredAt.timeIntervalSinceReferenceDate.isFinite,
      createdAt.timeIntervalSinceReferenceDate.isFinite
    else {
      throw AgentError.memoryFailure("Episodic memory dates must be finite.")
    }
    guard Self.reservedKeys.allSatisfy({ metadata[$0] == nil }) else {
      throw AgentError.memoryFailure("Episodic memory metadata uses a reserved key.")
    }
    var attributes = metadata
    attributes[Self.categoryKey] = "episodic"
    attributes[Self.kindKey] = kind.rawValue
    attributes[Self.versionKey] = "1"
    attributes[Self.occurrenceKey] = String(occurredAt.timeIntervalSinceReferenceDate)
    return Memory(id: id, content: content, createdAt: createdAt, metadata: attributes)
  }

  /// Decodes a version-one episodic record, preserving app metadata and both timestamps.
  /// - Throws: `AgentError.memoryFailure` for another category, unsupported kind/version,
  /// missing or invalid occurrence metadata, blank content or non-finite dates.
  public init(memory: Memory) throws {
    guard memory.metadata[Self.categoryKey] == "episodic",
      memory.metadata[Self.versionKey] == "1",
      let kind = memory.metadata[Self.kindKey].flatMap(Kind.init(rawValue:)),
      let seconds = memory.metadata[Self.occurrenceKey].flatMap(Double.init), seconds.isFinite
    else {
      throw AgentError.memoryFailure("Invalid or unsupported episodic memory record.")
    }
    var attributes = memory.metadata
    for key in Self.reservedKeys { attributes.removeValue(forKey: key) }
    self.init(
      id: memory.id, kind: kind, content: memory.content,
      occurredAt: Date(timeIntervalSinceReferenceDate: seconds), createdAt: memory.createdAt,
      metadata: attributes)
    _ = try self.memory()
  }
}

extension MemoryStore {
  /// Explicitly records a past event/action without executing tools or invoking a model.
  /// Apps obtain any required consent before calling this host API. Recording an action does not
  /// authorize its execution or replay. Typed store failures and cancellation propagate.
  public func save(_ episodicMemory: EpisodicMemory) async throws {
    if Task.isCancelled { throw AgentError.cancelled }
    try await save(episodicMemory.memory())
  }

  /// Searches episodic records, optionally restricted to events or actions, before limiting.
  /// Text matching and ordering follow the store (SwiftData orders by createdAt, not occurredAt).
  /// Invalid matched records throw a typed memory failure. No runtime state or prompts change;
  /// automatic retrieval and automatic episode recording are not enabled by this helper.
  public func searchEpisodic(
    text: String, kind: EpisodicMemory.Kind? = nil, limit: Int = 5
  ) async throws -> [EpisodicMemory] {
    if Task.isCancelled { throw AgentError.cancelled }
    guard limit > 0 else { return [] }
    var metadata = [EpisodicMemory.categoryKey: "episodic"]
    if let kind { metadata[EpisodicMemory.kindKey] = kind.rawValue }
    let records = try await search(MemoryQuery(text: text, limit: limit, metadata: metadata))
    if Task.isCancelled { throw AgentError.cancelled }
    return try records.map { try EpisodicMemory(memory: $0) }
  }
}
