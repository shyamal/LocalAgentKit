import CoreGraphics
import CoreText
import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import LocalAgentKitTools
import Testing

@Suite struct PDFDocumentLoaderTests {
  @Test func lazyPDFSourceExtractsAndIngestsInsideBackgroundJob() async throws {
    let url = try fixture(["Budget review preparation", "Project actions"])
    defer { try? FileManager.default.removeItem(at: url) }
    let source = DocumentIngestionSource { try DocumentExtractor.load(contentsOf: url) }
    let store = MockVectorStore()
    let job = try IngestionJob.start(
      sources: [source],
      pipeline: RetrievalPipeline(embeddingProvider: MockEmbeddingProvider(), vectorStore: store),
      batchSize: 1)
    let progress = try await job.value()
    #expect(progress.state == .completed && progress.completedDocuments == 1)
    #expect(progress.committedBatches == 1)
    let stored = await store.stored
    #expect(stored.map(\.text) == ["Budget review preparation\n\nProject actions"])
  }

  @Test func unifiedExtractorDispatchesPDFAndForwardsPasswordAndLimits() throws {
    let url = try fixture(["Budget review"], ext: "PDF", password: "reader")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try DocumentExtractor.load(contentsOf: url, password: "reader").text == "Budget review")
    try expectRetrievalFailure { _ = try DocumentExtractor.load(contentsOf: url) }
    try expectRetrievalFailure {
      _ = try DocumentExtractor.load(
        contentsOf: url, password: "reader",
        limits: .init(maximumCharacters: 3))
    }
  }

  @Test func preservesPageOrderSeparatorsAndFilenameTitle() throws {
    let url = try fixture(["Budget review preparation", "Project sync checklist"], ext: "PDF")
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try PDFDocumentLoader.load(contentsOf: url)
    #expect(document.title == url.deletingPathExtension().lastPathComponent)
    #expect(document.text == "Budget review preparation\n\nProject sync checklist")
  }

  @Test func plainFileBytesAtLimitAreAcceptedAndOneByteLessIsRejected() throws {
    let url = try fixture(["Budget review"])
    defer { try? FileManager.default.removeItem(at: url) }
    let size = try Data(contentsOf: url).count
    _ = try PDFDocumentLoader.load(contentsOf: url, limits: .init(maximumBytes: size))
    try expectRetrievalFailure {
      _ = try PDFDocumentLoader.load(contentsOf: url, limits: .init(maximumBytes: size - 1))
    }
  }

  @Test func pageAndCharacterLimitsIncludePageSeparators() throws {
    let url = try fixture(["One", "Two"])
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try PDFDocumentLoader.load(
      contentsOf: url, limits: .init(maximumPages: 2, maximumCharacters: 8))
    try expectRetrievalFailure {
      _ = try PDFDocumentLoader.load(contentsOf: url, limits: .init(maximumPages: 1))
    }
    try expectRetrievalFailure {
      _ = try PDFDocumentLoader.load(contentsOf: url, limits: .init(maximumCharacters: 7))
    }
    let unicode = try fixture(["Café"])
    defer { try? FileManager.default.removeItem(at: unicode) }
    #expect(
      try PDFDocumentLoader.load(contentsOf: unicode, limits: .init(maximumCharacters: 4)).text
        == "Café")
    try expectRetrievalFailure {
      _ = try PDFDocumentLoader.load(contentsOf: unicode, limits: .init(maximumCharacters: 3))
    }
  }

  @Test func corruptMissingDirectoryAndRemoteInputsFailAsTypedRetrievalErrors() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("directory.pdf")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let wrongExtension = try fixture(["Valid PDF, unsupported extension"], ext: "txt")
    defer { try? FileManager.default.removeItem(at: wrongExtension) }
    let corrupt = root.appendingPathComponent("broken.pdf")
    try Data("not a PDF".utf8).write(to: corrupt)
    for url in [
      corrupt, root.appendingPathComponent("missing.pdf"), directory, wrongExtension,
      try #require(URL(string: "https://example.invalid/private.pdf")),
    ] {
      try expectRetrievalFailure { _ = try PDFDocumentLoader.load(contentsOf: url) }
    }
  }

  @Test func invalidLimitsFailBeforeReading() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing.pdf")
    for limits in [
      PDFDocumentLoader.Limits(maximumBytes: 0), .init(maximumPages: -1),
      .init(maximumCharacters: 0),
    ] {
      try expectRetrievalFailure { _ = try PDFDocumentLoader.load(contentsOf: url, limits: limits) }
    }
  }

  @Test func blankDocumentsFailAndBlankPagesInMixedDocumentsRemainSeparated() throws {
    let blank = try fixture([nil])
    let mixed = try fixture(["One", nil, "Three"])
    defer {
      try? FileManager.default.removeItem(at: blank)
      try? FileManager.default.removeItem(at: mixed)
    }
    try expectRetrievalFailure { _ = try PDFDocumentLoader.load(contentsOf: blank) }
    #expect(try PDFDocumentLoader.load(contentsOf: mixed).text == "One\n\n\n\nThree")
  }

  @Test func encryptedPDFRequiresCorrectPasswordAndDoesNotDiscloseIt() throws {
    let url = try fixture(["Private meeting"], password: "fixture-secret")
    defer { try? FileManager.default.removeItem(at: url) }
    try expectRetrievalFailure { _ = try PDFDocumentLoader.load(contentsOf: url) }
    do {
      _ = try PDFDocumentLoader.load(contentsOf: url, password: "wrong-secret")
      Issue.record("Expected password rejection")
    } catch {
      #expect(!String(describing: error).contains("wrong-secret"))
    }
    #expect(
      try PDFDocumentLoader.load(contentsOf: url, password: "fixture-secret").text
        == "Private meeting")
  }

  @Test func imageOnlyPDFDoesNotSilentlyIngestAsEmptyText() throws {
    let url = try fixture([nil], imageOnly: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try expectRetrievalFailure { _ = try PDFDocumentLoader.load(contentsOf: url) }
  }

  @Test func largeInputStopsAtByteBudgetBeforePDFParsing() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(repeating: 65, count: 131_072).write(to: url)
    do {
      _ = try PDFDocumentLoader.load(contentsOf: url, limits: .init(maximumBytes: 65_536))
      Issue.record("Expected bounded-read rejection")
    } catch { #expect(error as? AgentError == .retrievalFailure("PDF exceeds its byte limit")) }
  }

  @Test func userPasswordCannotBypassCopyRestrictions() throws {
    let url = try fixture(["Restricted text"], password: "reader", copying: false)
    defer { try? FileManager.default.removeItem(at: url) }
    try expectRetrievalFailure {
      _ = try PDFDocumentLoader.load(contentsOf: url, password: "reader")
    }
  }

  @Test func cancellationIsTypedAndDoesNotReturnAnEmptyDocument() async throws {
    let url = try fixture(["Not ingested"])
    defer { try? FileManager.default.removeItem(at: url) }
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let task = Task {
      for await _ in stream { break }
      return try PDFDocumentLoader.load(contentsOf: url)
    }
    task.cancel()
    continuation.finish()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch { #expect(error as? AgentError == .cancelled) }
  }

  @Test func extractedTextReachesExistingIngestionAndRetrievalWithoutModelAssets() async throws {
    let url = try fixture(["Budget review preparation"])
    defer { try? FileManager.default.removeItem(at: url) }
    let embedding = MockEmbeddingProvider()
    let store = MockVectorStore()
    let pipeline = RetrievalPipeline(embeddingProvider: embedding, vectorStore: store)
    try await pipeline.ingest(PDFDocumentLoader.load(contentsOf: url))
    #expect(await store.stored.first?.text == "Budget review preparation")
    #expect(
      try await pipeline.retrieve(for: "Budget review preparation") == ["Budget review preparation"]
    )
  }
}

private func expectRetrievalFailure(_ operation: () throws -> Void) throws {
  do {
    try operation()
    Issue.record("Expected retrieval failure")
  } catch {
    guard case .retrievalFailure = error as? AgentError else {
      Issue.record("Expected typed retrieval failure, got \(error)")
      return
    }
  }
}

private func fixture(
  _ pages: [String?], ext: String = "pdf", password: String? = nil, copying: Bool = true,
  imageOnly: Bool = false
) throws -> URL {
  let data = NSMutableData()
  let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
  var box = CGRect(x: 0, y: 0, width: 500, height: 400)
  var options: [String: Any] = [:]
  if let password {
    options[kCGPDFContextOwnerPassword as String] = "fixture-owner"
    options[kCGPDFContextUserPassword as String] = password
    options[kCGPDFContextAllowsCopying as String] = copying
  }
  let context = try #require(CGContext(consumer: consumer, mediaBox: &box, options as CFDictionary))
  for text in pages {
    context.beginPDFPage(nil)
    if let text {
      context.textPosition = CGPoint(x: 30, y: 300)
      let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
      let string = NSAttributedString(
        string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
      CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    if imageOnly {
      let bitmap = try #require(
        CGContext(
          data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)))
      bitmap.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
      bitmap.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
      context.draw(
        try #require(bitmap.makeImage()), in: CGRect(x: 30, y: 30, width: 100, height: 100))
    }
    context.endPDFPage()
  }
  context.closePDF()
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "\(UUID().uuidString).\(ext)")
  try (data as Data).write(to: url)
  return url
}
