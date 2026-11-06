import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

@Suite struct IngestionJobTests {
  actor Gate {
    var opened = false
    var reached = false
    var waiting: CheckedContinuation<Void, Never>?
    var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
      reached = true
      for observer in observers { observer.resume() }
      observers = []
      if !opened { await withCheckedContinuation { waiting = $0 } }
    }
    func entered() async {
      if !reached { await withCheckedContinuation { observers.append($0) } }
    }
    func release() {
      opened = true
      waiting?.resume()
      waiting = nil
    }
  }
  actor Store: VectorStore {
    var batches: [[EmbeddedDocument]] = []
    let fail: Bool
    let gate: Gate?
    init(fail: Bool = false, gate: Gate? = nil) {
      self.fail = fail
      self.gate = gate
    }
    func insert(_ documents: [EmbeddedDocument]) async throws {
      if fail { throw AgentError.retrievalFailure("store failed") }
      batches.append(documents)
      if let gate { await gate.pause() }
    }
    func search(vector: [Float], limit: Int) async throws -> [SearchResult] { [] }
  }
  struct Embedding: EmbeddingProvider {
    let gate: Gate?
    let failure: Bool
    init(gate: Gate? = nil, failure: Bool = false) {
      self.gate = gate
      self.failure = failure
    }
    func embed(text: String) async throws -> [Float] {
      if let gate { await gate.pause() }
      if failure { throw AgentError.retrievalFailure("embedding failed") }
      return [1, 0]  // Deliberately ignores cancellation so the job must check after awaiting.
    }
  }

  @Test func sourcesCommitBoundedBatchesAndFinishWithCumulativeProgress() async throws {
    let store = Store()
    let document = Document(title: "Title", text: "one two three four five six seven")
    let chunker = Chunker(configuration: .init(chunkSize: 5, overlap: 0))
    let expected = chunker.chunk(document)
    let job = try IngestionJob.start(
      sources: [.init(document: document), .init(document: Document(title: "blank", text: ""))],
      pipeline: .init(embeddingProvider: Embedding(), vectorStore: store), chunker: chunker,
      batchSize: 2)
    let result = try await job.value()
    let batches = await store.batches
    #expect(batches.map(\.count) == [2, 2, 2, 1])
    #expect(batches.flatMap { $0 }.map(\.text) == expected.map(\.text))
    #expect(batches.flatMap { $0 }.allSatisfy { $0.metadata["title"] == "Title" })
    #expect(result.state == .completed && result.completedDocuments == 2)
    #expect(result.totalDocuments == 2 && result.committedChunks == expected.count)
    #expect(result.committedBatches == 4 && result.currentSourceID == nil)
    #expect(await final(job) == result)
  }

  @Test func emptyJobCompletesWithoutProviders() async throws {
    let store = Store(fail: true)
    let job = try IngestionJob.start(
      sources: [], pipeline: .init(embeddingProvider: Embedding(failure: true), vectorStore: store))
    let value = try await job.value()
    #expect(value.state == .completed && value.committedChunks == 0 && value.totalDocuments == 0)
    #expect(await store.batches.isEmpty)
  }

  @Test @MainActor func lazySynchronousLoadingDoesNotRunOnTheMainThread() async throws {
    let source = DocumentIngestionSource {
      Self.synchronousLoad()
    }
    let job = try IngestionJob.start(
      sources: [source], pipeline: .init(embeddingProvider: Embedding(), vectorStore: Store()))
    #expect(try await job.value().completedDocuments == 1)
  }

  @Test func snapshotsAreObservableDuringLoadingAndBufferOnlyLatestState() async throws {
    let gate = Gate()
    let source = DocumentIngestionSource {
      await gate.pause()
      return Document(title: "source", text: "One")
    }
    let job = try IngestionJob.start(
      sources: [source], pipeline: .init(embeddingProvider: Embedding(), vectorStore: Store()))
    await gate.entered()
    var iterator = job.events.makeAsyncIterator()
    if case .ingestionProgress(let progress) = await iterator.next() {
      #expect(progress.state == .running && progress.currentSourceID == source.id)
      #expect(progress.committedBatches == 0 && progress.completedDocuments == 0)
    } else {
      Issue.record("Missing running progress")
    }
    await gate.release()
    let value = try await job.value()
    if case .ingestionProgress(let progress) = await iterator.next() {
      #expect(progress == value)
    } else {
      Issue.record("Missing terminal progress")
    }
    #expect(await iterator.next() == nil)
  }

  @Test func cancellationAfterUncooperativeLoaderStopsEmbeddingAndCommits() async throws {
    let gate = Gate()
    let store = Store()
    let job = try IngestionJob.start(
      sources: [
        .init {
          await gate.pause()
          return Document(title: "t", text: "One")
        }
      ],
      pipeline: .init(embeddingProvider: Embedding(failure: true), vectorStore: store))
    await gate.entered()
    job.cancel()
    await gate.release()
    await cancelled(job)
    #expect(await store.batches.isEmpty)
    #expect(await final(job)?.state == .cancelled)
  }

  @Test func cancellationAfterUncooperativeEmbeddingDiscardsPendingBatch() async throws {
    let gate = Gate()
    let store = Store()
    let job = try IngestionJob.start(
      sources: [.init(document: Document(title: "t", text: "One"))],
      pipeline: .init(embeddingProvider: Embedding(gate: gate), vectorStore: store))
    await gate.entered()
    job.cancel()
    await gate.release()
    await cancelled(job)
    #expect(await store.batches.isEmpty)
    #expect(await final(job)?.committedChunks == 0)
  }

  @Test func cancellationDuringSuccessfulInsertCountsTheCommittedBatch() async throws {
    let gate = Gate()
    let store = Store(gate: gate)
    let job = try IngestionJob.start(
      sources: [.init(document: Document(title: "t", text: "one two three"))],
      pipeline: .init(embeddingProvider: Embedding(), vectorStore: store),
      chunker: Chunker(configuration: .init(chunkSize: 3, overlap: 0)), batchSize: 1)
    await gate.entered()
    job.cancel()
    await gate.release()
    await cancelled(job)
    #expect(await store.batches.count == 1)
    let progress = await final(job)
    #expect(
      progress?.state == .cancelled && progress?.committedChunks == 1
        && progress?.committedBatches == 1)
    #expect(progress?.completedDocuments == 0)
  }

  @Test func cancellingAValueWaiterCancelsTheSharedJob() async throws {
    let gate = Gate()
    let job = try IngestionJob.start(
      sources: [
        .init {
          await gate.pause()
          try await Task.sleep(for: .seconds(60))
          return Document(title: "t", text: "One")
        }
      ],
      pipeline: .init(embeddingProvider: Embedding(), vectorStore: Store()))
    await gate.entered()
    let waiter = Task { try await job.value() }
    waiter.cancel()
    await gate.release()
    do {
      _ = try await waiter.value
      Issue.record("Expected cancellation")
    } catch { #expect(error as? AgentError == .cancelled) }
    #expect(await final(job)?.state == .cancelled)
  }

  @Test func laterSourceFailureRetainsEarlierSuccessfulCommit() async throws {
    enum Failure: Error { case bad }
    let store = Store()
    let job = try IngestionJob.start(
      sources: [
        .init(document: Document(title: "first", text: "One")), .init { throw Failure.bad },
      ],
      pipeline: .init(embeddingProvider: Embedding(), vectorStore: store))
    do {
      _ = try await job.value()
      Issue.record("Expected failure")
    } catch { #expect(error as? AgentError == .retrievalFailure("Document ingestion failed")) }
    #expect(await store.batches.count == 1)
    let progress = await final(job)
    #expect(progress?.completedDocuments == 1 && progress?.committedChunks == 1)
    #expect(progress?.state == .failed(.retrievalFailure("Document ingestion failed")))
  }

  @Test func embeddingAndStoreFailuresAreTerminalAndTyped() async throws {
    for failEmbedding in [true, false] {
      let store = Store(fail: !failEmbedding)
      let job = try IngestionJob.start(
        sources: [.init(document: Document(title: "t", text: "One"))],
        pipeline: .init(embeddingProvider: Embedding(failure: failEmbedding), vectorStore: store))
      let error = AgentError.retrievalFailure(failEmbedding ? "embedding failed" : "store failed")
      do {
        _ = try await job.value()
        Issue.record("Expected failure")
      } catch let caught { #expect(caught as? AgentError == error) }
      #expect(await final(job)?.state == .failed(error))
      #expect(await store.batches.isEmpty)
    }
  }

  @Test func thrownCancellationIsMappedAndStreamsFinish() async throws {
    let job = try IngestionJob.start(
      sources: [.init { throw CancellationError() }],
      pipeline: .init(embeddingProvider: Embedding(), vectorStore: Store()))
    await cancelled(job)
    #expect(await final(job)?.state == .cancelled)
  }

  @Test func configurationAndNetworkDeclarationsAreCheckedBeforeWork() async throws {
    let pipeline = RetrievalPipeline(
      embeddingProvider: MockEmbeddingProvider(), vectorStore: MockVectorStore())
    #expect(throws: AgentError.self) {
      try IngestionJob.start(sources: [], pipeline: pipeline, batchSize: 0)
    }
    #expect(throws: AgentError.self) {
      try IngestionJob.start(
        sources: [], pipeline: pipeline,
        chunker: Chunker(configuration: .init(chunkSize: 0)))
    }
    #expect(throws: AgentError.self) {
      try IngestionJob.start(
        sources: [],
        pipeline: .init(
          embeddingProvider: MockEmbeddingProvider(requiresNetwork: true),
          vectorStore: MockVectorStore()))
    }
    let source = DocumentIngestionSource(requiresNetwork: true) { Document(title: "t", text: "") }
    #expect(throws: AgentError.self) {
      try IngestionJob.start(sources: [source], pipeline: pipeline)
    }
    let job = try IngestionJob.start(sources: [source], pipeline: pipeline, networkPolicy: .allowed)
    #expect(try await job.value().state == .completed)
  }

  @Test func cancelledCallerCannotStartDetachedWork() async throws {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      #expect(throws: AgentError.cancelled) {
        try IngestionJob.start(
          sources: [],
          pipeline: .init(embeddingProvider: Embedding(), vectorStore: Store()))
      }
    }
    await task.value
  }

  private static func synchronousLoad() -> Document {
    #expect(!Thread.isMainThread)
    return Document(title: "source", text: "One")
  }

  private func final(_ job: IngestionJob) async -> IngestionProgress? {
    var last: IngestionProgress?
    for await event in job.events {
      if case .ingestionProgress(let progress) = event { last = progress }
    }
    return last
  }
  private func cancelled(_ job: IngestionJob) async {
    do {
      _ = try await job.value()
      Issue.record("Expected cancellation")
    } catch { #expect(error as? AgentError == .cancelled) }
  }
}
