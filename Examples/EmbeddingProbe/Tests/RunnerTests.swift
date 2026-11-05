import Foundation
import LocalAgentKitCore
import Testing

@testable import EmbeddingProbeChecks

@Suite struct RunnerTests {
  private var corpus: ProbeCorpus {
    ProbeCorpus(
      documents: [.init(id: "d", text: "Document")],
      queries: [.init(id: "q", text: "Query")])
  }
  @Test func completedExportPreservesAllIDsHashMetadataAndRoundTrips() async throws {
    let report = try await ProbeRunner.run(
      corpus: corpus, digest: "hash",
      paths: [ProbePath(name: "mock", metadata: ["revision": "test"], embed: { _ in [1, 0] })],
      metadata: ["os": "test"])
    let result = try #require(report.results.first)
    #expect(result.status == .completed)
    #expect(result.export?.vectors.keys.sorted() == ["d", "q"])
    #expect(result.export?.corpusSHA256 == "hash")
    #expect(result.export?.metadata == ["os": "test", "revision": "test"])
    #expect(result.elapsedMilliseconds >= 0)
    let decoded = try JSONDecoder().decode(ProbeReport.self, from: JSONEncoder().encode(report))
    #expect(decoded.runID == report.runID)
    #expect(decoded.results.first?.export?.vectors == result.export?.vectors)
  }
  @Test func unavailableAndFailedPathsDoNotHideAnotherCompletedPath() async throws {
    let report = try await ProbeRunner.run(
      corpus: corpus, digest: "hash",
      paths: [
        ProbePath(name: "missing", metadata: [:], embed: nil),
        ProbePath(
          name: "fails", metadata: [:],
          embed: { text in
            if text == "Query" { throw AgentError.retrievalFailure("Synthetic failure") }
            return [1, 0]
          }),
        ProbePath(name: "works", metadata: [:], embed: { _ in [1, 0] }),
      ], metadata: [:])
    #expect(report.results.map(\.status) == [.unavailable, .failed, .completed])
    #expect(report.results[0].export == nil)
    #expect(report.results[1].export == nil)
    #expect(report.results[1].failure?.contains("Synthetic failure") == true)
  }
  @Test(arguments: [0, 1, 2, 3])
  func invalidVectorsCannotBePublishedAsCompleted(kind: Int) async throws {
    let report = try await ProbeRunner.run(
      corpus: corpus, digest: "hash",
      paths: [
        ProbePath(
          name: "invalid", metadata: [:],
          embed: { text in
            switch kind {
            case 0: return []
            case 1: return [.nan]
            case 2: return [0, 0]
            default: return text == "Query" ? [1] : [1, 0]
            }
          })
      ], metadata: [:])
    #expect(report.results.first?.status == .failed)
    #expect(report.results.first?.export == nil)
  }
  @Test func duplicateCorpusIDsAreRejectedBeforeEmbedding() async {
    do {
      _ = try await ProbeRunner.run(
        corpus: ProbeCorpus(
          documents: [.init(id: "same", text: "A")], queries: [.init(id: "same", text: "B")]),
        digest: "hash", paths: [], metadata: [:])
      Issue.record("Expected invalid corpus rejection")
    } catch {
      #expect(
        error as? AgentError == .retrievalFailure("Invalid benchmark corpus or duplicate paths"))
    }
  }
  @Test func cancellationAfterUncooperativeEmbeddingDoesNotPublishCompletion() async throws {
    let (ready, signal) = AsyncStream<Void>.makeStream()
    let gate = ProbePause(signal: signal)
    let task = Task {
      try await ProbeRunner.run(
        corpus: corpus, digest: "hash",
        paths: [
          ProbePath(name: "paused", metadata: [:], embed: { _ in await gate.pause() })
        ], metadata: [:])
    }
    for await _ in ready { break }
    task.cancel()
    await gate.resume()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
  }
  @Test func typedProviderCancellationIsTerminal() async {
    do {
      _ = try await ProbeRunner.run(
        corpus: corpus, digest: "hash",
        paths: [
          ProbePath(name: "cancelled", metadata: [:], embed: { _ in throw AgentError.cancelled })
        ], metadata: [:])
      Issue.record("Expected terminal cancellation")
    } catch { #expect(error as? AgentError == .cancelled) }
  }
}
private actor ProbePause {
  let signal: AsyncStream<Void>.Continuation
  var continuation: CheckedContinuation<[Float], Never>?
  init(signal: AsyncStream<Void>.Continuation) { self.signal = signal }
  func pause() async -> [Float] {
    await withCheckedContinuation {
      continuation = $0
      signal.yield(())
    }
  }
  func resume() {
    continuation?.resume(returning: [1, 0])
    continuation = nil
  }
}
