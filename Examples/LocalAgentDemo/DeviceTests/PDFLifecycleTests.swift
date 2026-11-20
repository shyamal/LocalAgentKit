import CoreGraphics
import CoreText
import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders
import LocalAgentKitSwiftUI
import LocalAgentKitTesting
import XCTest

@testable import LocalAgentDemo

private actor ImportGate: EmbeddingProvider {
  private var entered = false
  private var observer: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?
  private let native = NLEmbeddingProvider()

  func embed(text: String) async throws -> [Float] {
    entered = true
    observer?.resume()
    observer = nil
    await withCheckedContinuation { release = $0 }
    return try await native.embed(text: text)
  }
  func waitForImport() async {
    if !entered { await withCheckedContinuation { observer = $0 } }
  }
  func resume() {
    release?.resume()
    release = nil
  }
}

private actor QuestionGate {
  private var entered = false
  private var observer: CheckedContinuation<Void, Never>?
  func answer() async throws -> ModelResponse {
    entered = true
    observer?.resume()
    observer = nil
    try await Task.sleep(for: .seconds(30))
    return .text("Late synthetic answer")
  }
  func waitForQuestion() async {
    if !entered { await withCheckedContinuation { observer = $0 } }
  }
}

@MainActor final class PDFLifecycleTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws {
    if let directory { try FileManager.default.removeItem(at: directory) }
  }

  func testSameFilenameReplacementAndReopeningDiscardPreviousContext() async throws {
    let old = try pdf("same.pdf", text: "The ALPHA project launch is in April.")
    let model = MockModelProvider { _ in .text("Synthetic answer.") }
    let controller = DemoPDFController(model: model)
    await controller.importPDF(old).value
    let original = try XCTUnwrap(controller.viewModel)
    let originalID = controller.sessionID
    original.send("When is the ALPHA project launch?")
    try await waitUntilIdle(original)
    let earlierRequests = await model.requests.count
    let replacement = try pdf("same.pdf", text: "The BETA project launch is in December.")
    await controller.importPDF(replacement).value
    let updated = try XCTUnwrap(controller.viewModel)
    XCTAssertFalse(original === updated)
    XCTAssertNotEqual(controller.sessionID, originalID)
    XCTAssertTrue(updated.turns.isEmpty)

    // Native PDFKit extraction and NaturalLanguage embeddings, with a scripted answer model.
    updated.send("When is the BETA project launch?")
    try await waitUntilIdle(updated)
    let requests = await model.requests
    let messages = requests.dropFirst(earlierRequests).flatMap(\.messages).map(\.content)
      .joined(separator: "\n")
    XCTAssertTrue(messages.contains("BETA"))
    XCTAssertFalse(messages.contains("ALPHA"))
    controller.cancel()  // Same action used by Done and onDisappear.
    XCTAssertNil(controller.viewModel)
    XCTAssertNil(controller.fileName)
    XCTAssertNil(controller.progress)
    let reopened = DemoPDFController(model: model)
    XCTAssertNil(reopened.viewModel)
    XCTAssertNil(reopened.fileName)
    await reopened.importPDF(replacement).value
    XCTAssertTrue(try XCTUnwrap(reopened.viewModel).turns.isEmpty)
    reopened.cancel()
  }

  func testCancelledNativeImportCannotPublishALateReadySession() async throws {
    let url = try pdf("cancel.pdf", text: "A synthetic passage for cancellation.")
    let gate = ImportGate()
    let controller = DemoPDFController(embedding: gate, model: MockModelProvider())
    let operation = controller.importPDF(url)
    await gate.waitForImport()
    XCTAssertTrue(controller.isImporting)
    XCTAssertNil(controller.viewModel)
    controller.cancel()
    await gate.resume()
    await operation.value
    XCTAssertFalse(controller.isImporting)
    XCTAssertNil(controller.viewModel)
    XCTAssertNil(controller.fileName)
    XCTAssertNil(controller.failure)
  }

  func testClosingDuringAQuestionCancelsWithoutPublishingAnAnswer() async throws {
    let url = try pdf("question.pdf", text: "The synthetic project launch is in December.")
    let gate = QuestionGate()
    let controller = DemoPDFController(model: MockModelProvider { _ in try await gate.answer() })
    await controller.importPDF(url).value
    let previous = try XCTUnwrap(controller.viewModel)
    previous.send("When is the project launch?")
    await gate.waitForQuestion()
    controller.cancel()
    try await waitUntilIdle(previous, expectSuccess: false)
    XCTAssertFalse(previous.turns.contains { $0.role == .assistant })
    XCTAssertNotNil(previous.lastFailure)
    XCTAssertNil(controller.viewModel)
    XCTAssertNil(controller.fileName)
    XCTAssertNil(controller.failure)
  }

  func testInvalidNativePDFsClearAnExistingReadySession() async throws {
    let valid = try pdf("valid.pdf", text: "Valid synthetic source.")
    let blank = try pdf("blank.pdf", text: nil)
    let locked = try pdf("locked.pdf", text: "Locked synthetic source.", password: "test-reader")
    let tooMany = try pdf("pages.pdf", text: nil, pages: 101)
    let corrupt = directory.appendingPathComponent("corrupt.pdf")
    try Data("not a PDF".utf8).write(to: corrupt)
    let oversized = directory.appendingPathComponent("oversized.pdf")
    try Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1).write(to: oversized)
    for url in [blank, locked, tooMany, corrupt, oversized] {
      let controller = DemoPDFController(model: MockModelProvider())
      await controller.importPDF(valid).value
      XCTAssertNotNil(controller.viewModel)
      await controller.importPDF(url).value
      XCTAssertNil(controller.viewModel)
      XCTAssertFalse(controller.isImporting)
      XCTAssertNotNil(controller.failure)
      controller.cancel()
    }
  }

  private func waitUntilIdle(_ model: AgentViewModel, expectSuccess: Bool = true) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while model.isRunning {
      guard ContinuousClock.now < deadline else {
        model.cancel()
        throw AgentError.modelUnavailable(reason: "Synthetic PDF question did not finish")
      }
      await Task.yield()
    }
    if expectSuccess { XCTAssertNil(model.lastFailure) }
  }

  private func pdf(_ name: String, text: String?, password: String? = nil, pages: Int = 1) throws
    -> URL
  {
    let data = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 500, height: 400)
    var options: [String: Any] = [:]
    if let password {
      options[kCGPDFContextOwnerPassword as String] = "synthetic-owner"
      options[kCGPDFContextUserPassword as String] = password
    }
    let context = try XCTUnwrap(
      CGContext(consumer: consumer, mediaBox: &box, options as CFDictionary))
    for _ in 0..<pages {
      context.beginPDFPage(nil)
      if let text {
        context.textPosition = CGPoint(x: 30, y: 300)
        let attributes: [NSAttributedString.Key: Any] = [
          .init(kCTFontAttributeName as String): CTFontCreateWithName(
            "Helvetica" as CFString, 12, nil)
        ]
        CTLineDraw(
          CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)),
          context)
      }
      context.endPDFPage()
    }
    context.closePDF()
    let url = directory.appendingPathComponent(name)
    try (data as Data).write(to: url)
    return url
  }
}
