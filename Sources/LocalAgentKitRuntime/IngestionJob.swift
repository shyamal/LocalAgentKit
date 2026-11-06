import Foundation
import LocalAgentKitCore

/// A host-authorized document source evaluated lazily inside an ingestion job.
/// The closure may call a synchronous file extractor; hosts own file scope and declare network use.
public struct DocumentIngestionSource: Sendable {
  /// Host-controlled source identity used in progress snapshots, not a passage/document ID.
  public let id: UUID
  /// Honest declaration for offline-policy validation, including provider-backed file downloads.
  public let requiresNetwork: Bool
  let load: @Sendable () async throws -> Document

  /// Wraps already-decoded text without file I/O or network access.
  public init(document: Document) {
    id = document.id
    requiresNetwork = false
    load = { document }
  }

  /// Creates a lazy loader; closures and providers choose their own isolation and cancellation behavior.
  public init(
    id: UUID = UUID(), requiresNetwork: Bool = false,
    load: @escaping @Sendable () async throws -> Document
  ) {
    self.id = id
    self.requiresNetwork = requiresNetwork
    self.load = load
  }
}

/// An explicitly owned utility-priority ingestion task, detached from the caller's actor.
/// Sources and embedding calls are sequential; at most `batchSize` vectors await insertion.
/// Whole-document text/chunks remain in memory. This is not OS background execution or a scheduler.
public struct IngestionJob: Sendable {
  /// Single-consumer AgentEvent stream, buffering only the newest cumulative snapshot.
  /// Slow consumers may miss intermediate states; the terminal snapshot remains until consumed.
  /// Dropping the stream does not cancel the task; call `cancel()` or cancel a `value()` waiter.
  public let events: AsyncStream<AgentEvent>
  private let task: Task<IngestionProgress, any Error>

  /// Validates configuration before starting work. Offline policy defaults to `.never` and rejects
  /// network-declaring sources/embeddings. VectorStore has no network declaration; hosts must
  /// supply a store consistent with policy. Source authorization and permissions stay host-owned.
  /// - Throws: `.cancelled` for a cancelled caller, or `.invalidConfiguration` for invalid settings/network use.
  public static func start(
    sources: [DocumentIngestionSource], pipeline: RetrievalPipeline,
    chunker: Chunker = Chunker(), batchSize: Int = 32, networkPolicy: NetworkPolicy = .never
  ) throws -> IngestionJob {
    if Task.isCancelled { throw AgentError.cancelled }
    guard batchSize > 0 else {
      throw AgentError.invalidConfiguration(.invalidLimit("ingestion batchSize must be positive"))
    }
    if let issue = chunker.configuration.issue { throw AgentError.invalidConfiguration(issue) }
    if networkPolicy == .never,
      pipeline.embeddingProvider.requiresNetwork || sources.contains(where: \.requiresNetwork)
    {
      throw AgentError.invalidConfiguration(.networkRequiredButForbidden(component: "ingestion"))
    }
    let (events, continuation) = AsyncStream<AgentEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let task = Task.detached(priority: .utility) {
      var progress = IngestionProgress(jobID: UUID(), totalDocuments: sources.count)
      func publish() { continuation.yield(.ingestionProgress(progress)) }
      func checkCancellation() throws {
        if Task.isCancelled { throw AgentError.cancelled }
      }
      defer { continuation.finish() }
      publish()
      do {
        try checkCancellation()
        for source in sources {
          try checkCancellation()
          progress.currentSourceID = source.id
          publish()
          let document = try await source.load()
          try checkCancellation()
          let chunks = chunker.chunk(document)
          try checkCancellation()
          var batch: [EmbeddedDocument] = []
          for (index, chunk) in chunks.enumerated() {
            try checkCancellation()
            let vector = try await pipeline.embeddingProvider.embed(text: chunk.text)
            try checkCancellation()
            batch.append(
              EmbeddedDocument(
                id: chunk.id, text: chunk.text, vector: vector, metadata: chunk.metadata))
            if batch.count == batchSize || index == chunks.count - 1 {
              try checkCancellation()
              try await pipeline.vectorStore.insert(batch)
              // A successful insertion is counted even if cancellation arrived during commit.
              progress.committedChunks += batch.count
              progress.committedBatches += 1
              publish()
              batch.removeAll(keepingCapacity: true)
              try checkCancellation()
            }
          }
          progress.completedDocuments += 1
          publish()
          await Task.yield()
          try checkCancellation()
        }
        progress.currentSourceID = nil
        progress.state = .completed
        publish()
        return progress
      } catch {
        let mapped: AgentError
        if error is CancellationError || (error as? AgentError) == .cancelled {
          mapped = .cancelled
        } else {
          mapped = error as? AgentError ?? .retrievalFailure("Document ingestion failed")
        }
        progress.state = mapped == .cancelled ? .cancelled : .failed(mapped)
        publish()
        throw mapped
      }
    }
    return IngestionJob(events: events, task: task)
  }

  /// Cooperatively stops further loading/embedding/inserts. Earlier committed batches are retained;
  /// cancellation cannot force an uncooperative provider or native parse to return.
  public func cancel() { task.cancel() }

  /// Awaits completion or a typed error. Cancelling this waiter also cancels the shared job;
  /// an already completed job still returns its result. Keep the handle alive to own its lifecycle.
  public func value() async throws -> IngestionProgress {
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
