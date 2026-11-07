import CoreGraphics
import CoreText
import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

@testable import DemoSetup

@Suite struct PDFSessionTests {
  actor Gate {
    var reached = false
    var waiting: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    func pause() async {
      reached = true
      observer?.resume()
      observer = nil
      await withCheckedContinuation { waiting = $0 }
    }
    func entered() async { if !reached { await withCheckedContinuation { observer = $0 } } }
    func release() {
      waiting?.resume()
      waiting = nil
    }
  }
  actor DelayedEmbedding: EmbeddingProvider {
    let gate: Gate
    var calls = 0
    init(_ gate: Gate) { self.gate = gate }
    func embed(text: String) async throws -> [Float] {
      calls += 1
      if calls == 1 { await gate.pause() }
      return [1, 0]
    }
  }

  @Test func actualPDFIndexesThenAnswersWithOneSearchAndOneModelCall() async throws {
    let url = try pdf(["The project launch date is 14 November."])
    defer { try? FileManager.default.removeItem(at: url) }
    let model = MockModelProvider { _ in .text("The launch is 14 November [1].") }
    let session = DemoPDFSession(embedding: MockEmbeddingProvider())
    let job = try session.start(url)
    #expect(try await job.value().state == .completed)
    let runtime = try session.runtime(model: model)
    let response = try await runtime.run("When is the project launch?")
    #expect(response.text == "The launch is 14 November [1].")
    #expect(response.toolCallCount == 1 && response.iterations <= 3)
    let requests = await model.requests
    #expect(requests.count == 1)
    #expect(requests[0].tools.isEmpty)
    #expect(
      requests[0].messages.contains {
        $0.content.contains("The project launch date is 14 November.")
      })
  }

  @Test func emptyCorpusReturnsBoundedNoEvidenceWithoutModelCall() async throws {
    let model = MockModelProvider()
    let session = DemoPDFSession(embedding: MockEmbeddingProvider())
    let runtime = try session.runtime(model: model)
    let response = try await runtime.run("What is the launch date?")
    #expect(response.text.contains("couldn't retrieve supporting passages"))
    #expect(response.toolCallCount == 1)
    #expect(await model.requests.isEmpty)
  }

  @Test func replacementSessionDoesNotRetrieveEarlierPDF() async throws {
    let first = DemoPDFSession(embedding: MockEmbeddingProvider())
    let second = DemoPDFSession(embedding: MockEmbeddingProvider())
    let url = URL(fileURLWithPath: "/fixture.pdf")
    _ = try await first.start(url, load: { _ in Document(title: "First", text: "OLD_PRIVATE_PDF") })
      .value()
    _ = try await second.start(
      url, load: { _ in Document(title: "Second", text: "NEW_SELECTED_PDF") }
    ).value()
    let model = MockModelProvider { _ in .text("New answer") }
    _ = try await second.runtime(model: model).run("What does this PDF say?")
    let messages = await model.requests.flatMap(\.messages).map(\.content)
    #expect(messages.contains { $0.contains("NEW_SELECTED_PDF") })
    #expect(!messages.contains { $0.contains("OLD_PRIVATE_PDF") })
  }

  @Test func lockedBlankAndOverPageLimitPDFsFailBeforeReady() async throws {
    let locked = try pdf(["Protected text"], password: "reader")
    let blank = try pdf([nil])
    let tooMany = try pdf(Array(repeating: nil, count: 101))
    defer { for url in [locked, blank, tooMany] { try? FileManager.default.removeItem(at: url) } }
    for url in [locked, blank, tooMany] {
      let session = DemoPDFSession(embedding: MockEmbeddingProvider())
      let job = try session.start(url)
      await #expect(throws: AgentError.self) { try await job.value() }
      #expect(await session.store.count == 0)
    }
  }

  @Test func importByteLimitRejectsOversizedInputBeforePDFParsing() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1).write(to: url)
    let session = DemoPDFSession(embedding: MockEmbeddingProvider())
    let job = try session.start(url)
    await #expect(throws: AgentError.retrievalFailure("PDF exceeds its byte limit")) {
      try await job.value()
    }
  }

  @Test @MainActor func controllerPublishesReadyOnlyAfterSuccessfulIndexing() async throws {
    let gate = Gate()
    let controller = DemoPDFController(
      embedding: DelayedEmbedding(gate), model: MockModelProvider(),
      load: { _ in Document(title: "Selected", text: "Project preparation") })
    let task = controller.importPDF(URL(fileURLWithPath: "/selected.pdf"))
    await gate.entered()
    #expect(controller.isImporting && controller.viewModel == nil)
    await gate.release()
    await task.value
    #expect(!controller.isImporting && controller.viewModel != nil && controller.failure == nil)
    #expect(controller.progress?.state == .completed)
    controller.cancel()
    #expect(controller.viewModel == nil && controller.fileName == nil)
  }

  @Test @MainActor func failedImportClearsOldSessionAndShowsFailure() async throws {
    let controller = DemoPDFController(
      embedding: MockEmbeddingProvider(), model: MockModelProvider(),
      load: { url in
        if url.lastPathComponent == "bad.pdf" {
          throw AgentError.retrievalFailure("fixture failure")
        }
        return Document(title: "Good", text: "Previous selected PDF")
      })
    await controller.importPDF(URL(fileURLWithPath: "/good.pdf")).value
    #expect(controller.viewModel != nil)
    await controller.importPDF(URL(fileURLWithPath: "/bad.pdf")).value
    #expect(controller.viewModel == nil && controller.failure != nil && !controller.isImporting)
  }

  @Test @MainActor func embeddingFailureAfterPartialIndexDoesNotPublishReady() async throws {
    actor Failing: EmbeddingProvider {
      var calls = 0
      func embed(text: String) async throws -> [Float] {
        calls += 1
        if calls == 9 { throw AgentError.retrievalFailure("fixture asset unavailable") }
        return [1, 0]
      }
    }
    let embedding = Failing()
    let controller = DemoPDFController(
      embedding: embedding, model: MockModelProvider(),
      load: { _ in Document(title: "Long", text: String(repeating: "Passage text ", count: 600)) })
    await controller.importPDF(URL(fileURLWithPath: "/partial.pdf")).value
    #expect(await embedding.calls == 9)
    #expect(controller.viewModel == nil && !controller.isImporting && controller.failure != nil)
  }

  @Test @MainActor func sameFilenameReplacementGetsANewChatIdentity() async throws {
    let controller = DemoPDFController(
      embedding: MockEmbeddingProvider(), model: MockModelProvider(),
      load: { _ in Document(title: "Same name", text: "PDF fixture text") })
    let url = URL(fileURLWithPath: "/same.pdf")
    await controller.importPDF(url).value
    let previousID = controller.sessionID
    let previousModel = try #require(controller.viewModel)
    await controller.importPDF(url).value
    #expect(controller.sessionID != previousID)
    #expect(controller.viewModel !== previousModel)
    controller.cancel()
  }

  @Test @MainActor func cancelledLateImportCannotReplaceNewerSession() async throws {
    let gate = Gate()
    let controller = DemoPDFController(
      embedding: DelayedEmbedding(gate), model: MockModelProvider(),
      load: { url in Document(title: url.lastPathComponent, text: "PDF fixture text") })
    let old = controller.importPDF(URL(fileURLWithPath: "/old.pdf"))
    await gate.entered()
    await controller.importPDF(URL(fileURLWithPath: "/new.pdf")).value
    #expect(controller.viewModel != nil && controller.fileName == "new.pdf")
    await gate.release()
    await old.value
    #expect(
      controller.viewModel != nil && controller.fileName == "new.pdf" && controller.failure == nil)
    controller.cancel()
  }

  @Test @MainActor func cancellationDuringIndexingLeavesNoReadySession() async throws {
    let gate = Gate()
    let controller = DemoPDFController(
      embedding: DelayedEmbedding(gate), model: MockModelProvider(),
      load: { _ in Document(title: "Selected", text: "PDF fixture text") })
    let task = controller.importPDF(URL(fileURLWithPath: "/selected.pdf"))
    await gate.entered()
    controller.cancel()
    await gate.release()
    await task.value
    #expect(!controller.isImporting && controller.viewModel == nil && controller.failure == nil)
  }

  private func pdf(_ pages: [String?], password: String? = nil) throws -> URL {
    let data = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 500, height: 400)
    var options: [String: Any] = [:]
    if let password {
      options[kCGPDFContextOwnerPassword as String] = "fixture-owner"
      options[kCGPDFContextUserPassword as String] = password
    }
    let context = try #require(
      CGContext(consumer: consumer, mediaBox: &box, options as CFDictionary))
    for text in pages {
      context.beginPDFPage(nil)
      if let text {
        context.textPosition = CGPoint(x: 30, y: 300)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let string = NSAttributedString(
          string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
      }
      context.endPDFPage()
    }
    context.closePDF()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".pdf")
    try (data as Data).write(to: url)
    return url
  }
}
