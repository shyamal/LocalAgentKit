import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

@testable import DemoSetup

private let receiptText =
  "LOCAL DEMO CAFE\n2026-11-16\nSubtotal LKR 1100.00\nTax LKR 150.50\nTOTAL LKR 1250.50"

private func receiptStore() -> ReceiptExpenseStore {
  ReceiptExpenseStore(
    url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("expenses.json"))
}

@Suite struct ReceiptSessionTests {
  @Test func suggestionsAreConservativeAndMoneyIsIntegerBased() throws {
    let draft = ReceiptDraft.suggested(from: receiptText)
    #expect(draft.merchant == "LOCAL DEMO CAFE")
    #expect(draft.date == "2026-11-16")
    #expect(draft.total == "1250.50")
    #expect(draft.currency == "LKR")
    #expect(try draft.reviewed().totalMinorUnits == 125050)
    let ambiguous = ReceiptDraft.suggested(from: "Cafe\n11/10/26\nTOTAL $12.50\nTOTAL $13.50")
    #expect(ambiguous.date.isEmpty && ambiguous.currency.isEmpty && ambiguous.total.isEmpty)
    #expect(ReceiptDraft.suggested(from: "Cafe\nSubtotal 20.00").total.isEmpty)
    #expect(ReceiptDraft.suggested(from: "Cafe\nTOTAL -12.50").total.isEmpty)
    #expect(ReceiptDraft.suggested(from: "Cafe\nTOTAL 1.234.50").total.isEmpty)
    #expect(ReceiptDraft.suggested(from: "2026-11-16 or 2026-11-17").date.isEmpty)
  }

  @Test func invalidDatesAmountsAndCurrenciesCannotBeSaved() throws {
    let valid = ReceiptDraft.suggested(from: receiptText)
    for total in ["0", "-1.00", "1.001", "1e3", "1,20", "1000000.01", "NaN"] {
      var draft = valid
      draft.total = total
      #expect(throws: AgentError.self) { try draft.reviewed() }
    }
    for date in ["2026-02-30", "2025-02-29", "2026-13-01", "16/11/2026", "2026-11-16\n"] {
      var draft = valid
      draft.date = date
      #expect(throws: AgentError.self) { try draft.reviewed() }
    }
    var draft = valid
    draft.total = "0.01"
    #expect(try draft.reviewed().totalMinorUnits == 1)
    draft.currency = ""
    #expect(throws: AgentError.self) { try draft.reviewed() }
  }

  @Test(arguments: [true, false])
  func approvalControlsDurableStructuredExpenseWrites(approved: Bool) async throws {
    let store = receiptStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    let record = try ReceiptDraft.suggested(from: receiptText).reviewed()
    let model = ScriptedModelProvider(responses: [])
    let runtime = try ReceiptSession.runtime(store: store, model: model)
    let events = await runtime.events()
    let task = Task { try await runtime.run(ReceiptSession.input(record)) }
    var asked = false
    for await event in events {
      if case .permissionRequired(let call) = event {
        asked = true
        #expect(try await store.all().isEmpty)
        #expect(call.name == "save_receipt_expense")
        #expect(await runtime.resolvePermission(callID: call.id, approved: approved))
        break
      }
      if case .error = event { break }
    }
    #expect(asked)
    if approved {
      _ = try await task.value
    } else {
      await #expect(throws: AgentError.permissionDenied(tool: "save_receipt_expense")) {
        try await task.value
      }
    }
    let restored = try await ReceiptExpenseStore(url: store.url).all()
    #expect(restored == (approved ? [record] : []))
    #expect(await model.requests.isEmpty)
    if approved {
      let saved = try String(contentsOf: store.url, encoding: .utf8)
      #expect(!saved.contains("sourceText"))
      #expect(!saved.contains("Subtotal"))
    }
    await runtime.finishEvents()
  }

  @Test func corruptStoreIsPreservedAndRetryIsIdempotent() async throws {
    let store = receiptStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    let record = try ReceiptDraft.suggested(from: receiptText).reviewed()
    try await store.save(record)
    try await store.save(record)
    #expect(try await store.all() == [record])
    try Data("corrupt".utf8).write(to: store.url)
    await #expect(throws: AgentError.self) { try await store.save(record) }
    #expect(try Data(contentsOf: store.url) == Data("corrupt".utf8))
  }

  @Test func pendingApprovalCancellationCannotWriteTheReceipt() async throws {
    let store = receiptStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    let runtime = try ReceiptSession.runtime(store: store)
    let events = await runtime.events()
    let record = try ReceiptDraft.suggested(from: receiptText).reviewed()
    let task = Task { try await runtime.run(ReceiptSession.input(record)) }
    var callID: String?
    for await event in events {
      if case .permissionRequired(let call) = event {
        callID = call.id
        break
      }
      if case .error = event { break }
    }
    let id = try #require(callID)
    task.cancel()
    await #expect(throws: AgentError.cancelled) { try await task.value }
    #expect(!(await runtime.resolvePermission(callID: id, approved: true)))
    #expect(try await store.all().isEmpty)
    await runtime.finishEvents()
  }
}

private actor ReceiptLatch {
  var entered = false
  var waiter: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    await withCheckedContinuation { waiter = $0 }
  }
  func release() {
    waiter?.resume()
    waiter = nil
  }
}

@MainActor @Suite struct ReceiptControllerTests {
  @Test func replacingAnUncooperativeOCRRunCannotRestoreOldFields() async throws {
    let latch = ReceiptLatch()
    let vision = MockVisionProvider { image in
      if image.data == Data([1]) { await latch.wait() }
      return VisionResult(recognizedText: [
        .init(
          text: image.data == Data([1]) ? "OLD" : receiptText,
          confidence: 1, boundingBox: .init(x: 0, y: 0, width: 1, height: 1))
      ])
    }
    let controller = ReceiptController(vision: vision, store: receiptStore())
    let first = controller.read(ImageInput(data: Data([1])))
    while !(await latch.entered) { await Task.yield() }
    let second = controller.read(ImageInput(data: Data([2])))
    await second.value
    await latch.release()
    await first.value
    #expect(controller.draft?.merchant == "LOCAL DEMO CAFE")
    #expect(controller.imageData == Data([2]))
    #expect(!controller.busy)
  }

  @Test func emptyOrBlankImagesNeverProduceASavableDraft() async throws {
    let vision = MockVisionProvider()
    let controller = ReceiptController(vision: vision, store: receiptStore())
    await controller.read(ImageInput(data: Data())).value
    #expect(await vision.inputs.isEmpty)
    #expect(controller.draft == nil && controller.failure != nil)
    await controller.read(ImageInput(data: Data([1]))).value
    #expect(controller.draft == nil && controller.failure != nil)
    #expect(controller.save() == nil)
  }

  @Test func reviewedSnapshotIsImmutableWhileApprovalIsPending() async throws {
    let store = receiptStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    let controller = ReceiptController(vision: MockVisionProvider(), store: store)
    controller.draft = ReceiptDraft.suggested(from: receiptText)
    let task = try #require(controller.save())
    let deadline = ContinuousClock.now + .seconds(5)
    while controller.pendingCall == nil, controller.busy, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    let call = try #require(controller.pendingCall)
    let captured = try JSONDecoder().decode(
      ReceiptExpense.self, from: Data(try #require(call.arguments.string("record")).utf8))
    #expect(captured.totalMinorUnits == 125050)
    controller.draft?.total = "1.00"
    controller.resolve(true)
    await task.value
    #expect(try await store.all().first?.totalMinorUnits == 125050)
    #expect(controller.records.count == 1 && controller.notice != nil && controller.draft == nil)
    let reopened = ReceiptController(
      vision: MockVisionProvider(), store: ReceiptExpenseStore(url: store.url))
    await reopened.refresh()
    #expect(reopened.records == controller.records)
  }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALAGENTKIT_DEVICE_TESTS"] == "1"))
struct ReceiptNativeTests {
  @Test func bundledReceiptUsesNativeOCRAndReopensOnlyApprovedExpenseFields() async throws {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("LocalAgentDemo/Resources/receipt-sample.png")
    let vision = try AppleVisionProvider(textRecognition: .init())
    let output = try await vision.analyze(image: ImageInput(data: Data(contentsOf: source)))
    let record = try ReceiptDraft.suggested(from: output.text).reviewed()
    #expect(record.merchant == "LOCAL DEMO CAFE")
    #expect(
      record.totalMinorUnits == 125050 && record.currency == "LKR" && record.date == "2026-11-16")
    let store = receiptStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    let model = ScriptedModelProvider(responses: [])
    let runtime = try ReceiptSession.runtime(store: store, model: model)
    let events = await runtime.events()
    let task = Task { try await runtime.run(ReceiptSession.input(record)) }
    for await event in events {
      if case .permissionRequired(let call) = event {
        #expect(try await store.all().isEmpty)
        #expect(await runtime.resolvePermission(callID: call.id, approved: true))
        break
      }
      if case .error = event { break }
    }
    _ = try await task.value
    #expect(try await ReceiptExpenseStore(url: store.url).all() == [record])
    #expect(await model.requests.isEmpty)
    await runtime.finishEvents()
  }
}

extension ReceiptSessionTests {
  @Test func commonPrintedDatesAndSplitTotalsAreRecognizedWithoutGuessingConflicts() {
    for date in [
      "16/11/2026", "11/16/2026", "2026/11/16", "16-Nov-2026", "Nov 16, 2026", "16.11.26",
    ] {
      #expect(ReceiptTextParser.date(date) == "2026-11-16")
    }
    #expect(ReceiptTextParser.date("05/06/2026").isEmpty)
    #expect(ReceiptTextParser.date("2026-11-16 2026-11-17").isEmpty)
    for total in [
      "TOTAL\nLKR\n1,250.50", "Grand Total: Rs. 1,250.50/-", "AMOUNT DUE 1250,50",
      "Net Total 1.250,50",
    ] {
      #expect(ReceiptTextParser.total(total) == "1250.50")
    }
    #expect(ReceiptTextParser.total("TOTAL ITEMS 3\nTOTAL 20.00") == "20.00")
    #expect(ReceiptTextParser.total("TOTAL 20.00\nTOTAL 25.00").isEmpty)
    #expect(ReceiptTextParser.money("-1250.50") == nil)
    #expect(ReceiptTextParser.money("1.234.50") == nil)
  }

  @Test func ocrColumnsAreJoinedByRowBeforeFieldExtraction() {
    let observations: [VisionTextObservation] = [
      .init(
        text: "1250.50", confidence: 1, boundingBox: .init(x: 0.7, y: 0.1, width: 0.2, height: 0.03)
      ),
      .init(
        text: "Cafe", confidence: 1, boundingBox: .init(x: 0.1, y: 0.9, width: 0.2, height: 0.04)),
      .init(
        text: "TOTAL LKR", confidence: 1,
        boundingBox: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.03)),
      .init(
        text: "16/11/2026", confidence: 1,
        boundingBox: .init(x: 0.1, y: 0.7, width: 0.3, height: 0.03)),
    ]
    let draft = ReceiptDraft.suggested(
      from: ReceiptTextParser.rows(VisionResult(recognizedText: observations)))
    #expect(draft.merchant == "Cafe")
    #expect(draft.total == "1250.50")
    #expect(draft.date == "2026-11-16")
  }
}
