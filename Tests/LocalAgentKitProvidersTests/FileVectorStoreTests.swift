import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders
import LocalAgentKitTesting
import Testing

@Suite struct FileVectorStoreTests {
  @Test func missingStoreStartsEmptyAndReopeningPreservesAllFields() async throws {
    let url = location()
    defer { clean(url) }
    let store = try make(url)
    #expect(try await store.count() == 0)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    let input = EmbeddedDocument(
      text: "Café preparation", vector: [1, 0],
      metadata: ["documentID": "source", "sectionHeading": "# Budget"])
    try await store.insert([input])
    let reopened = try make(url)
    let results = try await reopened.search(vector: [1, 0], limit: 5)
    #expect(results.map(\.document) == [input])
    #expect(results.map(\.score) == [1])
    #expect(try await reopened.count() == 1)
  }

  @Test func upsertsAndLastBatchOccurrenceWinWithoutDuplicates() async throws {
    let url = location()
    defer { clean(url) }
    let store = try make(url)
    let first = EmbeddedDocument(text: "first", vector: [1, 0])
    var replacement = first
    replacement.text = "replacement"
    replacement.vector = [0, 1]
    try await store.insert([first, first])
    try await store.insert([first, replacement])
    #expect(try await store.count() == 1)
    #expect(try await make(url).search(vector: [0, 1], limit: 1).first?.document == replacement)
  }

  @Test func exactCosineRankingAndStableTies() async throws {
    let url = location()
    defer { clean(url) }
    let store = try make(url)
    let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let highID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let documents = [
      EmbeddedDocument(id: highID, text: "tie2", vector: [2, 0]),
      EmbeddedDocument(id: lowID, text: "tie1", vector: [1, 0]),
      EmbeddedDocument(text: "orthogonal", vector: [0, 1]),
      EmbeddedDocument(text: "opposite", vector: [-1, 0]),
    ]
    try await store.insert(documents)
    let hits = try await store.search(vector: [1, 0], limit: 10)
    #expect(hits.map(\.document.text) == ["tie1", "tie2", "orthogonal", "opposite"])
    #expect(hits.map(\.score) == [1, 1, 0, -1])
    #expect(try await store.search(vector: [], limit: 0).isEmpty)
    #expect(try await store.search(vector: [], limit: -1).isEmpty)
    #expect(try await store.search(vector: [1, 0], limit: 1).count == 1)
  }

  @Test func extremeFiniteVectorsDoNotOverflowCosine() async throws {
    let url = location()
    defer { clean(url) }
    let store = try make(url)
    let large = [Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude]
    let tiny = [Float.leastNonzeroMagnitude, Float.leastNonzeroMagnitude]
    try await store.insert([
      EmbeddedDocument(text: "large", vector: large),
      EmbeddedDocument(text: "tiny", vector: tiny),
    ])
    for query in [large, tiny] {
      let hits = try await store.search(vector: query, limit: 2)
      #expect(hits.allSatisfy { $0.score.isFinite && abs($0.score - 1) < 0.00001 })
    }
  }

  @Test func invalidVectorsRejectWholeBatchAndQueries() async throws {
    let url = location()
    defer { clean(url) }
    let store = try make(url)
    let original = EmbeddedDocument(text: "original", vector: [1, 0])
    try await store.insert([original])
    let before = try Data(contentsOf: url)
    for vector: [Float] in [[], [1], [0, 0], [.nan, 1], [.infinity, 1], [-.infinity, 1]] {
      await failure {
        try await store.insert([
          EmbeddedDocument(text: "valid", vector: [0, 1]),
          EmbeddedDocument(text: "invalid", vector: vector),
        ])
      }
      await failure { _ = try await store.search(vector: vector, limit: 1) }
      #expect(try Data(contentsOf: url) == before)
      #expect(try await store.count() == 1)
    }
  }

  @Test func removalsPersistAndMissingIDsDoNotWrite() async throws {
    let url = location()
    defer { clean(url) }
    let store = try make(url)
    let input = EmbeddedDocument(text: "delete", vector: [1, 0])
    try await store.insert([input])
    let before = try Data(contentsOf: url)
    try await store.remove(ids: [UUID()])
    try await store.insert([])
    #expect(try Data(contentsOf: url) == before)
    try await store.remove(ids: [input.id])
    #expect(try await make(url).count() == 0)
  }

  @Test func mismatchedSpacesDimensionsAndVersionsFailClosed() async throws {
    let url = location()
    defer { clean(url) }
    let store = try make(url)
    try await store.insert([EmbeddedDocument(text: "keep", vector: [1, 0])])
    let before = try Data(contentsOf: url)
    let other = try FileVectorStore(url: url, embeddingSpace: "other", dimensions: 2)
    let wrongDimensions = try FileVectorStore(url: url, embeddingSpace: "fixture-v1", dimensions: 3)
    await failure { _ = try await other.count() }
    await failure { try await wrongDimensions.insert([]) }
    #expect(try Data(contentsOf: url) == before)
    try edit(url) { $0["version"] = 99 }
    let future = try Data(contentsOf: url)
    await failure { try await make(url).insert([EmbeddedDocument(text: "new", vector: [1, 0])]) }
    #expect(try Data(contentsOf: url) == future)
  }

  @Test func corruptOrDuplicateRecordsAndMalformedStorageAreNeverOverwritten() async throws {
    let url = location()
    defer { clean(url) }
    let input = EmbeddedDocument(text: "keep", vector: [1, 0])
    try writeLegacy(url, documents: [input])
    let original = try Data(contentsOf: url)
    for mutation in 0..<4 {
      try original.write(to: url)
      try edit(url) { object in
        var records = object["records"] as! [[String: Any]]
        if mutation == 0 { records.append(records[0]) }
        if mutation == 1 { records[0]["vector"] = [0, 0] }
        if mutation == 2 { records[0]["vector"] = [1] }
        if mutation == 3 { object.removeValue(forKey: "dimensions") }
        object["records"] = records
      }
      let corrupted = try Data(contentsOf: url)
      await failure { try await make(url).insert([input]) }
      #expect(try Data(contentsOf: url) == corrupted)
    }
    try Data("not JSON".utf8).write(to: url)
    await failure { _ = try await make(url).search(vector: [1, 0], limit: 0) }
    #expect(try String(contentsOf: url, encoding: .utf8) == "not JSON")
  }

  @Test func exactReadBudgetAndOversizedWriteRollback() async throws {
    let url = location()
    defer { clean(url) }
    try await make(url).insert([EmbeddedDocument(text: "keep", vector: [1, 0])])
    let before = try Data(contentsOf: url)
    let exact = try make(url, maximumBytes: before.count)
    #expect(try await exact.count() == 1)
    await failure { _ = try await make(url, maximumBytes: before.count - 1).count() }
    await failure {
      try await exact.insert([
        EmbeddedDocument(text: String(repeating: "x", count: 1000), vector: [0, 1])
      ])
    }
    #expect(try await exact.count() == 1)
    #expect(try Data(contentsOf: url) == before)
  }

  @Test func multireadBudgetIsEnforcedBeforeJSONDecode() async throws {
    let url = location()
    defer { clean(url) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0xff, count: 70_000).write(to: url)
    do {
      _ = try await make(url, maximumBytes: 66_000).count()
      Issue.record("Expected byte-limit failure")
    } catch {
      #expect(error as? AgentError == .retrievalFailure("Vector snapshot exceeds byte limit"))
    }
  }

  @Test func failedWriteDoesNotPublishCachedCandidate() async throws {
    let url = location()
    defer { clean(url) }
    let store = try make(url)
    let input = EmbeddedDocument(text: "keep", vector: [1, 0])
    try await store.insert([input])
    let backup = url.appendingPathExtension("backup")
    try FileManager.default.moveItem(at: url, to: backup)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    await failure { try await store.insert([EmbeddedDocument(text: "new", vector: [0, 1])]) }
    await failure { try await store.remove(ids: [input.id]) }
    #expect(try await store.count() == 1)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: backup, to: url)
    #expect(try await make(url).search(vector: [1, 0], limit: 1).first?.document == input)
  }

  @Test func invalidConfigurationAndNonregularStorageAreTyped() async throws {
    let url = location()
    defer { clean(url) }
    for config in [("", 2, 100), (" ", 2, 100), ("valid", 0, 100), ("valid", 2, 0)] {
      #expect(throws: AgentError.self) {
        try FileVectorStore(
          url: url, embeddingSpace: config.0, dimensions: config.1, maximumBytes: config.2)
      }
    }
    #expect(throws: AgentError.self) { try make(URL(string: "https://example.com/store")!) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    await failure { _ = try await make(url).count() }
  }

  @Test func cancellationDoesNotReadOrCommit() async throws {
    let url = location()
    defer { clean(url) }
    let store = try make(url)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      for operation in 0..<4 {
        do {
          switch operation {
          case 0: try await store.insert([EmbeddedDocument(text: "no", vector: [1, 0])])
          case 1: _ = try await store.search(vector: [1, 0], limit: 1)
          case 2: try await store.remove(ids: [UUID()])
          default: _ = try await store.count()
          }
          Issue.record("Expected cancellation")
        } catch { #expect(error as? AgentError == .cancelled) }
      }
    }
    await task.value
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func oneActorSerializesConcurrentInserts() async throws {
    let url = location()
    defer { clean(url) }
    let store = try make(url)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<20 {
        group.addTask {
          try await store.insert([EmbeddedDocument(text: "passage \(index)", vector: [1, 0])])
        }
      }
      try await group.waitForAll()
    }
    #expect(try await make(url).count() == 20)
  }

  @Test func protocolAndPipelineComposeWithMockEmbeddings() async throws {
    let url = location()
    defer { clean(url) }
    let embedding = MockEmbeddingProvider()
    // Use the mock's actual vector dimension rather than making a model/hardware call.
    let dimension = try await embedding.embed(text: "Budget").count
    let actual = try FileVectorStore(url: url, embeddingSpace: "mock-space", dimensions: dimension)
    let store: any VectorStore = actual
    let pipeline = RetrievalPipeline(embeddingProvider: embedding, vectorStore: store)
    try await pipeline.ingest(Document(title: "Fixture", text: "Budget review preparation"))
    #expect(try await pipeline.retrieve(for: "Budget") == ["Budget review preparation"])
    #expect(try await actual.count() == 1)
  }

  @Test func legacyReadsDoNotRewriteAndFirstMutationMigratesAtomically() async throws {
    let url = location()
    defer { clean(url) }
    let original = EmbeddedDocument(
      text: "Legacy café", vector: [1, 0], metadata: ["source": "old"])
    try writeLegacy(url, documents: [original])
    let legacy = try Data(contentsOf: url)
    let store = try make(url, maximumBytes: legacy.count)
    #expect(try await store.search(vector: [1, 0], limit: 1).first?.document == original)
    #expect(try Data(contentsOf: url) == legacy)
    await failure {
      try await store.insert([
        EmbeddedDocument(text: String(repeating: "large", count: 1000), vector: [0, 1])
      ])
    }
    #expect(try Data(contentsOf: url) == legacy)
    #expect(try await store.count() == 1)
    // A separate actor takes ownership only after the preceding actor has finished its work.
    let migrating = try make(url)
    var replacement = original
    replacement.text = "Updated legacy passage"
    try await migrating.insert([replacement])
    #expect(try Data(contentsOf: url).starts(with: Data("bplist00".utf8)))
    #expect(try await make(url).search(vector: [1, 0], limit: 1).first?.document == replacement)
  }

  @Test func compactRoundTripPreservesEveryFloatBitIncludingSignedZero() async throws {
    let url = location()
    defer { clean(url) }
    let vector: [Float] = [
      1, -0.0, 0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
      .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
    ]
    let store = try FileVectorStore(url: url, embeddingSpace: "bits", dimensions: vector.count)
    try await store.insert([EmbeddedDocument(text: "Unicode 漢字 🐦", vector: vector)])
    let reopened = try FileVectorStore(url: url, embeddingSpace: "bits", dimensions: vector.count)
    let actual = try #require(await reopened.search(vector: vector, limit: 1).first)
    #expect(actual.document.vector.map(\.bitPattern) == vector.map(\.bitPattern))
    #expect(actual.document.text == "Unicode 漢字 🐦")
    let object =
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), format: nil) as! [String: Any]
    let record = (object["records"] as! [[String: Any]])[0]
    let bytes = record["vector"] as! Data
    #expect(Array(bytes.prefix(8)) == [0, 0, 128, 63, 0, 0, 0, 128])

  }

  @Test func compactCorruptionNeverReplacesStorageOrPublishesPartialCache() async throws {
    let url = location()
    defer { clean(url) }
    let input = EmbeddedDocument(text: "Keep", vector: [1, 0])
    try await make(url).insert([input])
    let original = try Data(contentsOf: url)
    for mutation in 0..<6 {
      try original.write(to: url)
      try edit(url) { object in
        var records = object["records"] as! [[String: Any]]
        switch mutation {
        case 0: records.append(records[0])
        case 1: records[0]["vector"] = Data([0])
        case 2: records[0]["vector"] = Data(repeating: 0, count: 8)
        case 3: records[0]["vector"] = Data([0, 0, 128, 127, 0, 0, 0, 0])
        case 4: object["dimensions"] = Int.max
        default: object.removeValue(forKey: "version")
        }
        object["records"] = records
      }
      let corrupt = try Data(contentsOf: url)
      let store = try make(url)
      await failure { _ = try await store.count() }
      await failure { try await store.insert([input]) }
      #expect(try Data(contentsOf: url) == corrupt)
      // Failed load must remain retryable without retaining a partial candidate.
      try original.write(to: url)
      #expect(try await store.count() == 1)
    }
    try original.dropLast().write(to: url)
    await failure { _ = try await make(url).count() }
  }

  @Test func denseCompactSnapshotIsSmallerThanLegacyWithoutChangingSearch() async throws {
    let url = location()
    defer { clean(url) }
    let values = (0..<512).map { Float($0 + 1) / 513 }
    let input = EmbeddedDocument(text: String(repeating: "passage", count: 146), vector: values)
    let store = try FileVectorStore(url: url, embeddingSpace: "dense", dimensions: 512)
    try await store.insert([input])
    let compact = try Data(contentsOf: url)
    try writeLegacy(url, documents: [input], space: "dense", dimensions: 512)
    let legacy = try Data(contentsOf: url)
    #expect(compact.count < legacy.count)
    let reopened = try FileVectorStore(url: url, embeddingSpace: "dense", dimensions: 512)
    #expect(try await reopened.search(vector: values, limit: 1).first?.document == input)
  }

  private func writeLegacy(
    _ url: URL, documents: [EmbeddedDocument], space: String = "fixture-v1", dimensions: Int = 2
  ) throws {
    let records: [[String: Any]] = documents.map {
      ["id": $0.id.uuidString, "text": $0.text, "vector": $0.vector, "metadata": $0.metadata]
    }
    let object: [String: Any] = [
      "version": 1, "embeddingSpace": space, "dimensions": dimensions, "records": records,
    ]
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: url)
  }

  private func location() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("vectors.json")
  }
  private func clean(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }
  private func make(_ url: URL, maximumBytes: Int = 32 * 1024 * 1024) throws -> FileVectorStore {
    try FileVectorStore(
      url: url, embeddingSpace: "fixture-v1", dimensions: 2, maximumBytes: maximumBytes)
  }
  private func failure(_ body: () async throws -> Void) async {
    do {
      try await body()
      Issue.record("Expected retrieval failure")
    } catch {
      guard case .retrievalFailure = error as? AgentError else {
        Issue.record("Expected typed retrieval failure, got \(error)")
        return
      }
    }
  }
  private func edit(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
    let data = try Data(contentsOf: url)
    if data.starts(with: Data("bplist00".utf8)) {
      var object =
        try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
      change(&object)
      try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        .write(to: url)
    } else {
      var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      change(&object)
      try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
  }
}
