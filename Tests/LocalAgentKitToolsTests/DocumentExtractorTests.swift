import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import LocalAgentKitTools
import Testing

@Suite struct DocumentExtractorTests {
  @Test func fileAliasesDispatchWithoutChangingPlainText() throws {
    for ext in ["txt", "TEXT", "md", "MARKDOWN"] {
      let url = try file(Data("# Café **notes**".utf8), ext: ext)
      defer { try? FileManager.default.removeItem(at: url) }
      let document = try DocumentExtractor.load(contentsOf: url)
      #expect(document.title == url.deletingPathExtension().lastPathComponent)
      #expect(
        document.text
          == (ext.lowercased() == "txt" || ext == "TEXT"
            ? "# Café **notes**" : "Café notes"))
    }
  }

  @Test func memoryTextPreservesTitleAndUsesTheSameMarkdownCleanup() throws {
    let input = "# Meeting\n- **Budget** [notes](https://example.com)"
    let plain = try DocumentExtractor.load(text: input, title: "Supplied title")
    let markdown = try DocumentExtractor.load(
      text: input, title: "Supplied title", format: .markdown)
    #expect(plain.title == "Supplied title")
    #expect(plain.text == input)
    #expect(markdown.text == "Meeting\nBudget notes")
    #expect(
      DocumentLoader.load(text: input, title: "Core", format: .markdown).text == markdown.text)
    #expect(DocumentLoader.load(text: input, title: "Core").text == input)
  }

  @Test func exactByteAndCharacterLimitsIncludeMarkdownSource() throws {
    let text = "**Café**"
    let url = try file(Data(text.utf8), ext: "md")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(
      try DocumentExtractor.load(
        contentsOf: url,
        limits: .init(maximumBytes: text.utf8.count, maximumCharacters: text.count)
      ).text == "Café")
    #expect(throws: AgentError.retrievalFailure("Document exceeds its byte limit")) {
      try DocumentExtractor.load(contentsOf: url, limits: .init(maximumBytes: text.utf8.count - 1))
    }
    #expect(throws: AgentError.self) {
      try DocumentExtractor.load(contentsOf: url, limits: .init(maximumCharacters: text.count - 1))
    }
    #expect(
      try DocumentExtractor.load(text: "Café", title: "", maximumCharacters: 4).text == "Café")
    #expect(throws: AgentError.self) {
      try DocumentExtractor.load(text: "Café", title: "", maximumCharacters: 3)
    }
  }

  @Test func invalidLimitsAndInvalidFilesAreTypedFailures() throws {
    let url = try file(Data([0xff, 0xfe, 0xff]), ext: "txt")
    defer { try? FileManager.default.removeItem(at: url) }
    for limits in [
      PDFDocumentLoader.Limits(maximumBytes: 0), .init(maximumPages: 0),
      .init(maximumCharacters: 0),
    ] {
      #expect(throws: AgentError.self) {
        try DocumentExtractor.load(contentsOf: url, limits: limits)
      }
    }
    #expect(throws: AgentError.retrievalFailure("Could not decode document as UTF-8 text")) {
      try DocumentExtractor.load(contentsOf: url)
    }
    #expect(throws: AgentError.self) {
      try DocumentExtractor.load(text: "", title: "", maximumCharacters: 0)
    }
    for input in [
      URL(string: "https://example.com/notes.txt")!,
      url.deletingPathExtension().appendingPathExtension("html"),
      url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".txt"),
    ] {
      #expect(throws: AgentError.self) { try DocumentExtractor.load(contentsOf: input) }
    }
    let directory = url.deletingPathExtension().appendingPathExtension("md")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: AgentError.self) { try DocumentExtractor.load(contentsOf: directory) }
  }

  @Test func emptyTextAndFilesArePreserved() throws {
    let url = try file(Data(), ext: "txt")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try DocumentExtractor.load(contentsOf: url).text.isEmpty)
    #expect(try DocumentExtractor.load(text: "", title: "Empty").title == "Empty")
  }

  @Test func multiReadLimitFailsBeforeTextDecoding() throws {
    let url = try file(Data(repeating: 0xff, count: 70_000), ext: "txt")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: AgentError.retrievalFailure("Document exceeds its byte limit")) {
      try DocumentExtractor.load(contentsOf: url, limits: .init(maximumBytes: 66_000))
    }
  }

  @Test func cancellationIsTypedForFilesAndMemory() async throws {
    let url = try file(Data("Notes".utf8), ext: "txt")
    defer { try? FileManager.default.removeItem(at: url) }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      #expect(throws: AgentError.cancelled) { try DocumentExtractor.load(contentsOf: url) }
      #expect(throws: AgentError.cancelled) { try DocumentExtractor.load(text: "Notes", title: "") }
    }
    await task.value
  }

  @Test func extractedTextFeedsExistingRetrievalWithoutFrameworkValues() async throws {
    let url = try file(Data("# Budget review preparation".utf8), ext: "md")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = MockVectorStore()
    let pipeline = RetrievalPipeline(embeddingProvider: MockEmbeddingProvider(), vectorStore: store)
    try await pipeline.ingest(DocumentExtractor.load(contentsOf: url))
    #expect(try await pipeline.retrieve(for: "Budget") == ["Budget review preparation"])
  }

  private func file(_ data: Data, ext: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(ext)
    try data.write(to: url)
    return url
  }
}
