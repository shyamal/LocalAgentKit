import CoreGraphics
import CoreText
import Foundation
import ImageIO
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitProviders

@Suite struct AppleVisionDocumentTests {
  typealias Options = AppleVisionProvider.DocumentRecognitionConfiguration
  static let box = VisionBoundingBox(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
  static let cell = VisionDocumentCell(
    text: "TEA", rowRange: 0...0, columnRange: 0...1, boundingBox: box)
  static let table = VisionDocumentTable(
    rowCount: 1, columnCount: 2, cells: [cell], boundingBox: box)
  static let document = VisionDocumentObservation(
    text: "TEA", title: "Invoice", paragraphs: ["TEA"], tables: [table], confidence: 0.9,
    boundingBox: box)

  @Test func preservesDocumentStructureAndConfigurationThroughTheProtocol() async throws {
    let options = try Options(languages: ["en-US"])
    let provider = try AppleVisionProvider(documentRecognition: options) { image, received in
      #expect(received == options && image.orientation == .right)
      return [Self.document]
    }
    let data = try AppleVisionProviderTests.imageData(orientation: .right)
    let result = try await provider.analyze(image: ImageInput(data: data))
    #expect(result.documents == [Self.document])
    #expect(result.text == "TEA")
    #expect(result.documents[0].tables[0].cells[0].columnRange == 0...1)
    #expect(result.classifications.isEmpty && result.recognizedText.isEmpty)
    #expect(!provider.requiresNetwork)
  }

  @Test func emptyRecognitionReturnsAnEmptyResult() async throws {
    let provider = try AppleVisionProvider(documentRecognition: Options()) { _, _ in [] }
    let data = try AppleVisionProviderTests.imageData()
    #expect(try await provider.analyze(image: ImageInput(data: data)) == VisionResult())
  }

  @Test func invalidConfigurationIsRejected() {
    for limits in [
      (0, 1, 1, 1, 1), (1, 0, 1, 1, 1), (1, 1, 0, 1, 1), (1, 1, 1, 0, 1), (1, 1, 1, 1, 0),
    ] {
      #expect(throws: AgentError.self) {
        try Options(
          maximumDocuments: limits.0, maximumParagraphs: limits.1,
          maximumTables: limits.2, maximumCells: limits.3, maximumCharacters: limits.4)
      }
    }
    #expect(throws: AgentError.self) { try Options(languages: [" "]) }
  }

  @Test func aggregateLimitsRejectPartialStructuresAndCountAllText() async throws {
    let data = try AppleVisionProviderTests.imageData()
    // Transcript 3 + title 7 + paragraph 3 + cell 3 = 16 Swift characters.
    let exact = try AppleVisionProvider(documentRecognition: Options(maximumCharacters: 16)) {
      _, _ in [Self.document]
    }
    #expect(try await exact.analyze(image: ImageInput(data: data)).documents == [Self.document])
    for options in [
      try Options(maximumDocuments: 1), try Options(maximumParagraphs: 1),
      try Options(maximumTables: 1), try Options(maximumCells: 1),
      try Options(maximumCharacters: 32),
    ] {
      let provider = try AppleVisionProvider(documentRecognition: options) { _, _ in
        [Self.document, Self.document]
      }
      await #expect(throws: AgentError.self) {
        try await provider.analyze(image: ImageInput(data: data))
      }
    }
  }

  @Test func malformedConfidenceGeometryAndCellSpansAreRejected() async throws {
    let data = try AppleVisionProviderTests.imageData()
    let outOfBounds = VisionDocumentCell(
      text: "x", rowRange: 0...1, columnRange: 0...0, boundingBox: Self.box)
    let duplicate = VisionDocumentTable(
      rowCount: 1, columnCount: 2, cells: [Self.cell, Self.cell], boundingBox: Self.box)
    let wrongSpan = VisionDocumentTable(
      rowCount: 1, columnCount: 1, cells: [outOfBounds], boundingBox: Self.box)
    let invalid = [
      VisionDocumentObservation(text: "x", confidence: .nan, boundingBox: Self.box),
      VisionDocumentObservation(
        text: "x", tables: [duplicate], confidence: 1, boundingBox: Self.box),
      VisionDocumentObservation(
        text: "x", tables: [wrongSpan], confidence: 1, boundingBox: Self.box),
      VisionDocumentObservation(
        text: "x", confidence: 1, boundingBox: .init(x: 0, y: 0, width: 2, height: 1)),
    ]
    for document in invalid {
      let provider = try AppleVisionProvider(documentRecognition: Options()) { _, _ in [document] }
      await #expect(throws: AgentError.self) {
        try await provider.analyze(image: ImageInput(data: data))
      }
    }
  }

  @Test func admissionErrorsAndCancellationUseTheSharedPath() async throws {
    let options = try Options()
    let data = try AppleVisionProviderTests.imageData()
    let unreadable = try AppleVisionProvider(documentRecognition: options) { _, _ in
      Issue.record("Unreadable image reached document recognition")
      return []
    }
    await #expect(throws: AgentError.self) {
      try await unreadable.analyze(image: ImageInput(data: Data()))
    }
    let broken = try AppleVisionProvider(documentRecognition: options) { _, _ in
      throw CocoaError(.fileReadCorruptFile)
    }
    await #expect(throws: AgentError.visionFailure("Document recognition failed")) {
      try await broken.analyze(image: ImageInput(data: data))
    }
    let typed = try AppleVisionProvider(documentRecognition: options) { _, _ in
      throw AgentError.visionFailure("scripted")
    }
    await #expect(throws: AgentError.visionFailure("scripted")) {
      try await typed.analyze(image: ImageInput(data: data))
    }
    let cancelled = try AppleVisionProvider(documentRecognition: options) { _, _ in
      throw CancellationError()
    }
    await #expect(throws: AgentError.cancelled) {
      try await cancelled.analyze(image: ImageInput(data: data))
    }
    for cancelBefore in [true, false] {
      let provider = try AppleVisionProvider(documentRecognition: options) { _, _ in
        #expect(!cancelBefore)
        withUnsafeCurrentTask { $0?.cancel() }
        return [Self.document]
      }
      await #expect(throws: AgentError.cancelled) {
        try await Task {
          if cancelBefore { withUnsafeCurrentTask { $0?.cancel() } }
          return try await provider.analyze(image: ImageInput(data: data))
        }.value
      }
    }
  }

  static func tableImage(blankCell: Bool = false) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: 800, height: 600,
        bitsPerComponent: 8, bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.setLineWidth(2)
    let x: [CGFloat] = [40, 300, 460, 740]
    let y: [CGFloat] = [500, 400, 300, 200]
    for value in x {
      context.move(to: CGPoint(x: value, y: 200))
      context.addLine(to: CGPoint(x: value, y: 500))
    }
    for value in y {
      context.move(to: CGPoint(x: 40, y: value))
      context.addLine(to: CGPoint(x: 740, y: value))
    }
    context.strokePath()
    let attributes: [NSAttributedString.Key: Any] = [
      .init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 30, nil),
      .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ]
    let rows = [
      ["ITEM", "QTY", "AMOUNT"], ["TEA", "2", "10.00"], ["CAKE", "1", blankCell ? "" : "5.00"],
    ]
    for (row, values) in rows.enumerated() {
      for (column, text) in values.enumerated() {
        context.textPosition = CGPoint(x: x[column] + 15, y: y[row + 1] + 35)
        CTLineDraw(
          CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)), context)
      }
    }
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALAGENTKIT_DEVICE_TESTS"] == "1"))
struct AppleVisionDocumentNativeTests {
  @Test(arguments: [false, true])
  func generatedTableRetainsNativeStructure(blankCell: Bool) async throws {
    let provider = try AppleVisionProvider(documentRecognition: .init(languages: ["en-US"]))
    let result = try await provider.analyze(
      image: ImageInput(data: AppleVisionDocumentTests.tableImage(blankCell: blankCell)))
    #expect(result.text.contains("TEA") && result.text.contains("10.00"))
    let tables = result.documents.flatMap(\.tables)
    #expect(!tables.isEmpty)
    #expect(tables.flatMap(\.cells).contains { $0.text.contains("TEA") })
    #expect(tables.allSatisfy { $0.rowCount >= 2 && $0.columnCount >= 2 })
  }

  @Test func blankImageHasNoDocumentText() async throws {
    let provider = try AppleVisionProvider(documentRecognition: .init())
    let data = try AppleVisionOCRTests.imageData(lines: [])
    #expect(try await provider.analyze(image: ImageInput(data: data)).text.isEmpty)
  }

  @Test func unsupportedDocumentLanguageFailsExplicitly() async throws {
    let provider = try AppleVisionProvider(documentRecognition: .init(languages: ["zz-ZZ"]))
    let data = try AppleVisionOCRTests.imageData(lines: ["DOCUMENT"])
    await #expect(throws: AgentError.visionFailure("Requested document language is unsupported")) {
      try await provider.analyze(image: ImageInput(data: data))
    }
  }
}
