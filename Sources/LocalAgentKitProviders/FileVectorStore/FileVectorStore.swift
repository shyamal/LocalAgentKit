import Foundation
import LocalAgentKitCore

/// Small-corpus local vector persistence using versioned JSON snapshots and exact cosine search.
/// Share one instance per file; independent actors/process writers are not coordinated. Hosts
/// own file authorization, provider-backed availability, backup and exclusive access. No network
/// operation is initiated, but a file URL does not establish that its backing volume is offline.
public actor FileVectorStore: VectorStore {
  private struct Record: Codable {
    let id: UUID
    let text: String
    let vector: [Float]
    let metadata: [String: String]

    init(_ document: EmbeddedDocument) {
      id = document.id
      text = document.text
      vector = document.vector
      metadata = document.metadata
    }
    var document: EmbeddedDocument {
      EmbeddedDocument(id: id, text: text, vector: vector, metadata: metadata)
    }
  }
  private struct Snapshot: Codable {
    let version: Int
    let embeddingSpace: String
    let dimensions: Int
    let records: [Record]
  }

  private let url: URL
  private let embeddingSpace: String
  private let dimensions: Int
  private let maximumBytes: Int
  private var documents: [EmbeddedDocument] = []
  private var loaded = false

  /// Configures a lazy store at an explicit local file; missing storage starts empty.
  /// `embeddingSpace` must identify model/revision/tokenization/pooling, not just dimensions.
  /// Reopening with different space/dimensions fails; hosts must re-embed into a separate store.
  /// `maximumBytes` (default 32 MiB) bounds reads and encoded writes, not peak process memory.
  /// - Throws: `.retrievalFailure` for a nonlocal URL, empty space or nonpositive limits.
  public init(
    url: URL, embeddingSpace: String, dimensions: Int, maximumBytes: Int = 32 * 1024 * 1024
  ) throws {
    guard url.isFileURL, !embeddingSpace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      dimensions > 0, maximumBytes > 0
    else { throw AgentError.retrievalFailure("Invalid local vector store configuration") }
    self.url = url
    self.embeddingSpace = embeddingSpace
    self.dimensions = dimensions
    self.maximumBytes = maximumBytes
  }

  /// Upserts by passage ID, last occurrence wins, preserving the first insertion position.
  /// Validates the whole batch and commits an atomic snapshot before publishing cached changes.
  /// Invalid vectors, corrupt storage and failed writes leave cached/persisted content unchanged.
  /// - Throws: `.cancelled` or `.retrievalFailure`; all vectors must be finite, nonzero and compatible.
  public func insert(_ documents: [EmbeddedDocument]) async throws {
    try checkCancellation()
    try load()
    guard !documents.isEmpty else { return }
    var candidate = self.documents
    var positions = Dictionary(
      uniqueKeysWithValues: candidate.enumerated().map { ($0.element.id, $0.offset) })
    for document in documents {
      try checkCancellation()
      try validate(document.vector)
      if let index = positions[document.id] {
        candidate[index] = document
      } else {
        positions[document.id] = candidate.count
        candidate.append(document)
      }
    }
    try commit(candidate)
  }

  /// Searches finite nonzero vectors of the configured dimension. Nonpositive limits yield no hits.
  /// Scores use Double intermediates and Float output, ordered descending; equal scores use UUID
  /// ascending. Storage validation still runs for nonpositive limits. No threshold/ANN index is used.
  /// - Throws: `.cancelled` or `.retrievalFailure` for invalid queries or unreadable/incompatible storage.
  public func search(vector: [Float], limit: Int) async throws -> [SearchResult] {
    try checkCancellation()
    try load()
    guard limit > 0 else { return [] }
    try validate(vector)
    let queryNorm = norm(vector)
    var scored: [SearchResult] = []
    for document in documents {
      try checkCancellation()
      var dot = 0.0
      for index in vector.indices { dot += Double(vector[index]) * Double(document.vector[index]) }
      let cosine = dot / (queryNorm * norm(document.vector))
      scored.append(SearchResult(document: document, score: Float(max(-1, min(1, cosine)))))
    }
    scored.sort {
      $0.score == $1.score
        ? $0.document.id.uuidString < $1.document.id.uuidString : $0.score > $1.score
    }
    try checkCancellation()
    return Array(scored.prefix(limit))
  }

  /// Durably removes matching passage IDs; absent IDs do nothing. Failed commits retain the cache.
  /// - Throws: `.cancelled` or `.retrievalFailure` for corrupt/unwritable storage.
  public func remove(ids: Set<UUID>) async throws {
    try checkCancellation()
    try load()
    let candidate = documents.filter { !ids.contains($0.id) }
    if candidate.count != documents.count { try commit(candidate) }
  }

  /// Returns the number of unique persisted passage IDs after lazy loading.
  /// - Throws: `.cancelled` or `.retrievalFailure` for invalid storage.
  public func count() async throws -> Int {
    try checkCancellation()
    try load()
    return documents.count
  }

  private func load() throws {
    guard !loaded else { return }
    do {
      let data = try read()
      let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
      guard snapshot.version == 1, snapshot.embeddingSpace == embeddingSpace,
        snapshot.dimensions == dimensions
      else {
        throw AgentError.retrievalFailure("Incompatible vector snapshot version or embedding space")
      }
      var ids: Set<UUID> = []
      for record in snapshot.records {
        try checkCancellation()
        try validate(record.vector)
        guard ids.insert(record.id).inserted else {
          throw AgentError.retrievalFailure("Duplicate IDs in vector snapshot")
        }
      }
      try checkCancellation()
      documents = snapshot.records.map(\.document)
      loaded = true
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      try checkCancellation()
      documents = []
      loaded = true
    } catch { throw mapped(error, operation: "load") }
  }

  private func read() throws -> Data {
    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      throw AgentError.retrievalFailure("Vector snapshot must be a regular file")
    }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var data = Data()
    while true {
      try checkCancellation()
      let remaining = maximumBytes - data.count
      let amount = remaining >= 65_536 ? 65_536 : remaining + 1
      guard let chunk = try file.read(upToCount: amount), !chunk.isEmpty else { return data }
      guard chunk.count <= remaining else {
        throw AgentError.retrievalFailure("Vector snapshot exceeds byte limit")
      }
      data.append(chunk)
    }
  }

  private func commit(_ candidate: [EmbeddedDocument]) throws {
    do {
      try checkCancellation()
      let snapshot = Snapshot(
        version: 1, embeddingSpace: embeddingSpace, dimensions: dimensions,
        records: candidate.map(Record.init))
      let data = try JSONEncoder().encode(snapshot)
      guard data.count <= maximumBytes else {
        throw AgentError.retrievalFailure("Vector snapshot exceeds byte limit")
      }
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try checkCancellation()
      try data.write(to: url, options: .atomic)
      // No cancellation check after commit: a successful write is reported as success.
      documents = candidate
    } catch { throw mapped(error, operation: "save") }
  }

  private func validate(_ vector: [Float]) throws {
    guard vector.count == dimensions, vector.allSatisfy(\.isFinite),
      vector.contains(where: { $0 != 0 })
    else {
      throw AgentError.retrievalFailure(
        "Vector must be finite, nonzero and match configured dimensions")
    }
  }

  private func norm(_ vector: [Float]) -> Double {
    vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
  }

  private func checkCancellation() throws {
    if Task.isCancelled { throw AgentError.cancelled }
  }

  private func mapped(_ error: any Error, operation: String) -> AgentError {
    if let error = error as? AgentError { return error }
    if error is CancellationError { return .cancelled }
    return .retrievalFailure("Could not \(operation) local vector snapshot")
  }
}
