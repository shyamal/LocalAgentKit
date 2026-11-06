import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

@Suite struct RetrievalSelectionTests {
  actor Store: VectorStore {
    let hits: [SearchResult]
    let error: AgentError?
    var limits: [Int] = []
    init(_ hits: [SearchResult] = [], error: AgentError? = nil) {
      self.hits = hits
      self.error = error
    }
    func insert(_ documents: [EmbeddedDocument]) async throws {}
    func search(vector: [Float], limit: Int) async throws -> [SearchResult] {
      limits.append(limit)
      if let error { throw error }
      return hits  // Deliberately may exceed the requested window or arrive unsorted.
    }
  }
  actor Embedding: EmbeddingProvider {
    var calls = 0
    let cancels: Bool
    init(cancels: Bool = false) { self.cancels = cancels }
    func embed(text: String) async throws -> [Float] {
      calls += 1
      if cancels { withUnsafeCurrentTask { $0?.cancel() } }
      return [1, 0]
    }
  }
  private func hit(_ text: String, _ score: Float, id: UUID = UUID()) -> SearchResult {
    SearchResult(document: EmbeddedDocument(id: id, text: text, vector: [1, 0]), score: score)
  }

  @Test func scoreFilteringDeduplicatesBeforeApplyingTopK() async throws {
    let store = Store([
      hit("duplicate", 0.9), hit("duplicate", 0.8), hit("boundary", 0.5), hit("low", 0.49),
    ])
    let pipeline = RetrievalPipeline(embeddingProvider: Embedding(), vectorStore: store)
    let config = RetrievalConfiguration(resultLimit: 2, candidateLimit: 4, minimumScore: 0.5)
    #expect(
      try await pipeline.retrieve(for: "q", configuration: config) == ["duplicate", "boundary"])
    #expect(await store.limits == [4])
  }

  @Test func ranksFiniteHitsAndBreaksTiesByStoreOrder() async throws {
    let store = Store([
      hit("low", -2), hit("tie first", 3), hit("tie second", 3), hit("nan", .nan),
      hit("inf", .infinity), hit(" \n\t", 4),
    ])
    let pipeline = RetrievalPipeline(embeddingProvider: Embedding(), vectorStore: store)
    let selected = try await pipeline.search(
      for: "q", configuration: .init(resultLimit: 6, candidateLimit: 6, deduplication: .none))
    #expect(selected.map(\.document.text) == ["tie first", "tie second", "low"])
    #expect(selected.map(\.score) == [3, 3, -2])
  }

  @Test func normalizationKeepsOriginalTextAndPreservesCaseAndPunctuation() async throws {
    let original = " Alpha\n\tBeta "
    let store = Store([
      hit(original, 1), hit("Alpha  Beta", 0.9), hit("alpha Beta", 0.8), hit("Alpha Beta!", 0.7),
    ])
    let pipeline = RetrievalPipeline(embeddingProvider: Embedding(), vectorStore: store)
    #expect(
      try await pipeline.retrieve(
        for: "q",
        configuration: .init(
          resultLimit: 4, candidateLimit: 4,
          deduplication: .normalizedWhitespace)) == [original, "alpha Beta", "Alpha Beta!"])
    #expect(
      try await pipeline.retrieve(
        for: "q",
        configuration: .init(
          resultLimit: 4, candidateLimit: 4,
          deduplication: .exactText)
      ).count == 4)
  }

  @Test func idDedupAndNoneHaveDistinctPolicies() async throws {
    let id = UUID()
    let store = Store([hit("first", 0.5, id: id), hit("changed", 1, id: id), hit("first", 0.4)])
    let pipeline = RetrievalPipeline(embeddingProvider: Embedding(), vectorStore: store)
    #expect(
      try await pipeline.retrieve(
        for: "q",
        configuration: .init(
          resultLimit: 3, candidateLimit: 3,
          deduplication: .passageID)) == ["changed", "first"])
    #expect(
      try await pipeline.retrieve(
        for: "q",
        configuration: .init(
          resultLimit: 3, candidateLimit: 3,
          deduplication: .none)) == ["changed", "first", "first"])
  }

  @Test func onlyBoundedCandidateWindowIsConsideredWithoutRefilling() async throws {
    let store = Store([hit("same", 0.9), hit("same", 0.8), hit("outside", 1)])
    let pipeline = RetrievalPipeline(embeddingProvider: Embedding(), vectorStore: store)
    #expect(
      try await pipeline.retrieve(for: "q", configuration: .init(resultLimit: 2, candidateLimit: 2))
        == ["same"])
    #expect(await store.limits == [2])
  }

  @Test func noThresholdCanAcceptUnrelatedEvidenceAndHighThresholdCanReturnNothing() async throws {
    let store = Store([hit("No supporting answer", 0.2)])
    let pipeline = RetrievalPipeline(embeddingProvider: Embedding(), vectorStore: store)
    #expect(
      try await pipeline.retrieve(for: "q", configuration: .init()) == ["No supporting answer"])
    #expect(try await pipeline.retrieve(for: "q", configuration: .init(minimumScore: 0.9)).isEmpty)
  }

  @Test func invalidSettingsFailBeforeEmbeddingOrStoreCalls() async throws {
    let embedding = Embedding()
    let store = Store()
    let pipeline = RetrievalPipeline(embeddingProvider: embedding, vectorStore: store)
    for config in [
      RetrievalConfiguration(resultLimit: 0), .init(candidateLimit: 0), .init(minimumScore: .nan),
      .init(minimumScore: .infinity), .init(minimumScore: -.infinity),
    ] {
      await #expect(throws: AgentError.self) {
        try await pipeline.search(for: "q", configuration: config)
      }
    }
    #expect(await embedding.calls == 0)
    #expect(await store.limits.isEmpty)
    #expect(RetrievalConfiguration(minimumScore: -20).issue == nil)
  }

  @Test func legacyLimitPathKeepsItsExistingDuplicatesAndOrder() async throws {
    let store = Store([hit("same", 0.5), hit("same", 1)])
    let pipeline = RetrievalPipeline(embeddingProvider: Embedding(), vectorStore: store)
    #expect(try await pipeline.retrieve(for: "q", limit: 2) == ["same", "same"])
    #expect(try await pipeline.retrieve(for: "q", limit: 0).isEmpty)
    #expect(await store.limits == [2])
  }

  @Test func cancellationAfterUncooperativeEmbeddingDoesNotSearch() async {
    let store = Store()
    let pipeline = RetrievalPipeline(
      embeddingProvider: Embedding(cancels: true), vectorStore: store)
    let task = Task {
      _ = await #expect(throws: AgentError.cancelled) {
        try await pipeline.retrieve(for: "q", configuration: .init())
      }
    }
    await task.value
    #expect(await store.limits.isEmpty)
  }

  @Test func providerFailuresRemainTyped() async {
    let pipeline = RetrievalPipeline(
      embeddingProvider: Embedding(), vectorStore: Store(error: .retrievalFailure("failure")))
    await #expect(throws: AgentError.retrievalFailure("failure")) {
      try await pipeline.search(for: "q", configuration: .init())
    }
  }

  @Test func unknownErrorsAndCancellationErrorsAreMapped() async {
    struct Failing: EmbeddingProvider {
      enum Failure: Error { case unknown }
      let cancellation: Bool
      func embed(text: String) async throws -> [Float] {
        if cancellation { throw CancellationError() }
        throw Failure.unknown
      }
    }
    for cancellation in [false, true] {
      let pipeline = RetrievalPipeline(
        embeddingProvider: Failing(cancellation: cancellation), vectorStore: Store())
      await #expect(
        throws: cancellation ? AgentError.cancelled : .retrievalFailure("Scored retrieval failed")
      ) {
        try await pipeline.retrieve(for: "q", configuration: .init())
      }
    }
  }

  @Test func runtimeOnlyInjectsSelectedPassagesThroughExistingContextFitting() async throws {
    let store = Store([hit("ACCEPTED_PASSAGE", 1), hit("DISCARDED_PASSAGE", 0.1)])
    let choice = ModelResponse.toolCall(
      ToolCall(
        id: "next", name: "choose_next_action",
        arguments: ToolArguments(["action": .string("finish")])))
    let model = ScriptedModelProvider(responses: [choice, .text("ok")])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(
        model: model,
        embedding: Embedding(), vectorStore: store,
        retrieval: .init(resultLimit: 1, candidateLimit: 2, minimumScore: 0.5)),
      tools: StaticToolSource([]))
    #expect(try await runtime.run("query").text == "ok")
    let requests = await model.requests
    #expect(requests.contains { $0.messages.contains { $0.content.contains("ACCEPTED_PASSAGE") } })
    #expect(
      !requests.contains { $0.messages.contains { $0.content.contains("DISCARDED_PASSAGE") } })
    #expect(await store.limits == [2])
  }

  @Test func runtimeRejectsInvalidSelectionAtConstruction() {
    #expect(throws: AgentError.self) {
      try AgentRuntime(
        configuration: AgentConfiguration(
          model: MockModelProvider(), retrieval: .init(resultLimit: 0)),
        tools: StaticToolSource([]))
    }
  }
}
