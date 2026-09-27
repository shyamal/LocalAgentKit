import Foundation
import Testing

@testable import LocalAgentKitCore

@Suite struct ChunkerTests {
  @Test func emptyTextProducesNoChunks() {
    #expect(Chunker().chunk(Document(title: "t", text: "")).isEmpty)
    #expect(Chunker().chunk(Document(title: "t", text: "   \n  ")).isEmpty)
  }

  @Test func shortTextIsOneChunk() {
    let document = Document(title: "t", text: "A short note about the budget.")
    let chunks = Chunker(configuration: ChunkerConfiguration(chunkSize: 800, overlap: 100))
      .chunk(document)
    #expect(chunks.count == 1)
    #expect(chunks[0].text == document.text)
    #expect(chunks[0].documentID == document.id)
    #expect(chunks[0].metadata["title"] == "t")
    #expect(chunks[0].metadata["chunkIndex"] == "0")
  }

  @Test func longTextIsSplitAndStaysWithinChunkSize() {
    let words = (1...500).map { "word\($0)" }
    let document = Document(title: "t", text: words.joined(separator: " "))
    let configuration = ChunkerConfiguration(chunkSize: 100, overlap: 20)
    let chunks = Chunker(configuration: configuration).chunk(document)
    #expect(chunks.count > 1)
    for chunk in chunks { #expect(chunk.text.count <= configuration.chunkSize) }
  }

  @Test func consecutiveChunksOverlap() {
    let words = (1...200).map { "w\($0)" }
    let document = Document(title: "t", text: words.joined(separator: " "))
    let chunks = Chunker(configuration: ChunkerConfiguration(chunkSize: 50, overlap: 20))
      .chunk(document)
    #expect(chunks.count > 1)
    let firstWords = Set(chunks[0].text.split(separator: " "))
    let secondWords = Set(chunks[1].text.split(separator: " "))
    #expect(!firstWords.isDisjoint(with: secondWords))
  }

  @Test func noChunkIsEmptyAndAllWordsAreCovered() {
    let words = (1...300).map { "token\($0)" }
    let document = Document(title: "t", text: words.joined(separator: " "))
    let chunks = Chunker(configuration: ChunkerConfiguration(chunkSize: 60, overlap: 10))
      .chunk(document)
    #expect(chunks.allSatisfy { !$0.text.isEmpty })
    let covered = Set(chunks.flatMap { $0.text.split(separator: " ") })
    #expect(covered.count == words.count)
  }

  @Test func chunkIndicesAreSequential() {
    let words = (1...300).map { "w\($0)" }
    let document = Document(title: "t", text: words.joined(separator: " "))
    let chunks = Chunker(configuration: ChunkerConfiguration(chunkSize: 40, overlap: 5))
      .chunk(document)
    #expect(chunks.map { $0.metadata["chunkIndex"] } == (0..<chunks.count).map { String($0) })
  }

  @Test func aSingleWordLongerThanChunkSizeStillProducesAChunk() {
    let document = Document(title: "t", text: String(repeating: "x", count: 500))
    let chunks = Chunker(configuration: ChunkerConfiguration(chunkSize: 50, overlap: 10))
      .chunk(document)
    #expect(!chunks.isEmpty)
    #expect(chunks.allSatisfy { !$0.text.isEmpty })
  }

  @Test func defaultConfigurationIsValid() {
    #expect(ChunkerConfiguration.default.issue == nil)
  }

  @Test func invalidConfigurationsAreCaught() {
    #expect(ChunkerConfiguration(chunkSize: 0).issue != nil)
    #expect(ChunkerConfiguration(overlap: -1).issue != nil)
    #expect(ChunkerConfiguration(chunkSize: 100, overlap: 100).issue != nil)
    #expect(ChunkerConfiguration(chunkSize: 100, overlap: 101).issue != nil)
  }
}

@Suite struct DocumentLoaderTests {
  private func write(_ contents: String, extension ext: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(UUID().uuidString).\(ext)")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  @Test func loadsPlainText() throws {
    let url = try write("Hello, this is plain text.", extension: "txt")
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try DocumentLoader.load(contentsOf: url)
    #expect(document.text == "Hello, this is plain text.")
    #expect(document.title == url.deletingPathExtension().lastPathComponent)
  }

  @Test func loadsAndStripsMarkdown() throws {
    let markdown = """
      # Title

      Some **bold** and _italic_ text with a [link](https://example.com).

      - one
      - two

      ```swift
      let x = 1
      ```
      """
    let url = try write(markdown, extension: "md")
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try DocumentLoader.load(contentsOf: url)
    #expect(!document.text.contains("#"))
    #expect(!document.text.contains("**"))
    #expect(!document.text.contains("_italic_"))
    #expect(document.text.contains("link"))
    #expect(!document.text.contains("https://example.com"))
    #expect(!document.text.contains("```"))
    #expect(document.text.contains("Title"))
    #expect(document.text.contains("bold"))
  }

  @Test func unsupportedExtensionIsATypedError() throws {
    let url = try write("%PDF-1.4", extension: "pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: AgentError.self) { try DocumentLoader.load(contentsOf: url) }
  }

  @Test func missingFileIsATypedError() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID()).txt")
    #expect(throws: AgentError.self) { try DocumentLoader.load(contentsOf: url) }
  }
}

@Suite struct RetrievalPipelineTests {
  /// A bag-of-words vector so texts sharing words score closer, without depending on any real
  /// embedding provider (Core has none — that is a Provider's job).
  private struct StubEmbedding: EmbeddingProvider {
    let requiresNetwork = false
    func embed(text: String) async throws -> [Float] {
      var vector = [Float](repeating: 0, count: 26)
      for scalar in text.lowercased().unicodeScalars where scalar.value >= 97 && scalar.value <= 122
      {
        vector[Int(scalar.value) - 97] += 1
      }
      return vector
    }
  }

  private actor StubVectorStore: VectorStore {
    private var documents: [EmbeddedDocument] = []
    var insertedCount: Int { documents.count }
    func insert(_ documents: [EmbeddedDocument]) async throws { self.documents += documents }
    func search(vector: [Float], limit: Int) async throws -> [SearchResult] {
      Array(
        documents.map { SearchResult(document: $0, score: Self.cosine(vector, $0.vector)) }
          .sorted { $0.score > $1.score }.prefix(limit))
    }
    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
      var dot: Float = 0
      for index in a.indices { dot += a[index] * b[index] }
      return dot
    }
  }

  @Test func ingestChunksEmbedsAndInserts() async throws {
    let store = StubVectorStore()
    let pipeline = RetrievalPipeline(embeddingProvider: StubEmbedding(), vectorStore: store)
    let words = (1...200).map { "term\($0)" }
    try await pipeline.ingest(
      Document(title: "t", text: words.joined(separator: " ")),
      chunker: Chunker(configuration: ChunkerConfiguration(chunkSize: 40, overlap: 5)))
    #expect(await store.insertedCount > 1)
  }

  @Test func ingestingEmptyTextInsertsNothing() async throws {
    let store = StubVectorStore()
    let pipeline = RetrievalPipeline(embeddingProvider: StubEmbedding(), vectorStore: store)
    try await pipeline.ingest(Document(title: "t", text: ""))
    #expect(await store.insertedCount == 0)
  }

  @Test func retrieveReturnsTextsMostRelevantFirst() async throws {
    let store = StubVectorStore()
    let pipeline = RetrievalPipeline(embeddingProvider: StubEmbedding(), vectorStore: store)
    try await pipeline.ingest(Document(title: "t", text: "the budget meeting notes"))
    try await pipeline.ingest(Document(title: "t", text: "a completely unrelated zoo visit"))
    let results = try await pipeline.retrieve(for: "budget meeting", limit: 5)
    #expect(results.first == "the budget meeting notes")
  }

  @Test func retrieveRespectsTheLimit() async throws {
    let store = StubVectorStore()
    let pipeline = RetrievalPipeline(embeddingProvider: StubEmbedding(), vectorStore: store)
    for index in 0..<10 {
      try await pipeline.ingest(Document(title: "t", text: "note number \(index) about budgets"))
    }
    let results = try await pipeline.retrieve(for: "budget", limit: 3)
    #expect(results.count == 3)
  }

  @Test func zeroLimitReturnsNothingWithoutCallingTheStore() async throws {
    let pipeline = RetrievalPipeline(
      embeddingProvider: StubEmbedding(), vectorStore: StubVectorStore())
    #expect(try await pipeline.retrieve(for: "anything", limit: 0).isEmpty)
  }
}
