import Foundation

/// A cumulative snapshot from a background ingestion job (M3-06); counts describe successful
/// store calls, not transaction guarantees of an arbitrary VectorStore implementation.
public struct IngestionProgress: Sendable, Hashable {
  /// Lifecycle of an ingestion job, separate from agent conversation execution.
  public enum State: Sendable, Hashable {
    /// Sources, chunks or embeddings are being processed.
    case running
    /// Every source completed successfully.
    case completed
    /// Cancellation stopped further work; committed batches remain.
    case cancelled
    /// A source/provider failed; committed batches remain.
    case failed(AgentError)
  }
  /// Correlates all snapshots for one job.
  public var jobID: UUID
  /// Current lifecycle, including any terminal error.
  public var state: State
  /// Total number of sources accepted at construction.
  public var totalDocuments: Int
  /// Sources that reached the end-of-source checkpoint, including blank documents.
  public var completedDocuments: Int
  /// Source currently being processed, nil at completion.
  public var currentSourceID: UUID?
  /// Number of passages acknowledged by successful insert calls.
  public var committedChunks: Int
  /// Number of successful nonempty insert calls.
  public var committedBatches: Int

  /// Creates a cumulative snapshot with no work committed by default.
  public init(
    jobID: UUID, state: State = .running, totalDocuments: Int,
    completedDocuments: Int = 0, currentSourceID: UUID? = nil,
    committedChunks: Int = 0, committedBatches: Int = 0
  ) {
    self.jobID = jobID
    self.state = state
    self.totalDocuments = totalDocuments
    self.completedDocuments = completedDocuments
    self.currentSourceID = currentSourceID
    self.committedChunks = committedChunks
    self.committedBatches = committedBatches
  }
}
