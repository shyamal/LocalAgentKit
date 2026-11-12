import CoreGraphics
import CoreText
import Foundation
import ImageIO
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitProviders

@Suite struct AppleVisionOCRTests {
  typealias Options = AppleVisionProvider.TextRecognitionConfiguration
  static let box = VisionBoundingBox(x: 0.1, y: 0.2, width: 0.4, height: 0.1)
  static func line(_ text: String) -> VisionTextObservation {
    .init(text: text, confidence: 0.8, boundingBox: box)
  }

  @Test func optionsOrientationAndObservationOrderSurviveAnalysis() async throws {
    let options = try Options(
      level: .fast, languages: ["en-US"], automaticallyDetectsLanguage: false,
      usesLanguageCorrection: false)
    let lines = [Self.line("First"), Self.line("Second")]
    let provider = try AppleVisionProvider(textRecognition: options) { image, received in
      #expect(received == options)
      #expect(image.orientation == .right)
      return lines
    }
    let data = try AppleVisionProviderTests.imageData(orientation: .right)
    let result = try await provider.analyze(image: ImageInput(data: data))
    #expect(result.recognizedText == lines)
    #expect(result.text == "First\nSecond")
    #expect(result.classifications.isEmpty)
    #expect(!provider.requiresNetwork)
  }

  @Test func emptyRecognitionIsAValidEmptyResult() async throws {
    let provider = try AppleVisionProvider(textRecognition: Options()) { _, _ in [] }
    let data = try AppleVisionProviderTests.imageData()
    #expect(try await provider.analyze(image: ImageInput(data: data)) == VisionResult())
  }

  @Test func rejectsInvalidOutputLimitsAndLanguageHints() {
    for values in [(0, 1, []), (1, 0, []), (1, 1, [" "])] as [(Int, Int, [String])] {
      #expect(
        throws: AgentError.invalidConfiguration(
          .invalidLimit("Invalid OCR limits or language hints"))
      ) {
        try Options(languages: values.2, maximumObservations: values.0, maximumCharacters: values.1)
      }
    }
  }

  @Test func completeOutputFitsLimitsIncludingUnicodeAndNewlines() async throws {
    let data = try AppleVisionProviderTests.imageData()
    let lines = [Self.line("é"), Self.line("👩🏽‍💻")]
    let exact = try AppleVisionProvider(
      textRecognition: Options(maximumObservations: 2, maximumCharacters: 3)
    ) { _, _ in lines }
    #expect(try await exact.analyze(image: ImageInput(data: data)).text == "é\n👩🏽‍💻")
    for (count, characters, message) in [
      (1, 3, "Recognized text exceeds the observation limit"),
      (2, 2, "Recognized text exceeds the character limit"),
    ] {
      let provider = try AppleVisionProvider(
        textRecognition: Options(maximumObservations: count, maximumCharacters: characters)
      ) { _, _ in lines }
      await #expect(throws: AgentError.visionFailure(message)) {
        try await provider.analyze(image: ImageInput(data: data))
      }
    }
  }

  @Test func rejectsMalformedTextConfidenceAndGeometry() async throws {
    let data = try AppleVisionProviderTests.imageData()
    let invalid = [
      VisionTextObservation(text: "", confidence: 1, boundingBox: Self.box),
      .init(text: "x", confidence: .nan, boundingBox: Self.box),
      .init(text: "x", confidence: -1, boundingBox: Self.box),
      .init(text: "x", confidence: 2, boundingBox: Self.box),
      .init(text: "x", confidence: 1, boundingBox: .init(x: .infinity, y: 0, width: 1, height: 1)),
      .init(text: "x", confidence: 1, boundingBox: .init(x: 0, y: 0, width: 0, height: 1)),
      .init(text: "x", confidence: 1, boundingBox: .init(x: 0.9, y: 0, width: 0.2, height: 1)),
    ]
    for observation in invalid {
      let provider = try AppleVisionProvider(textRecognition: Options()) { _, _ in [observation] }
      await #expect(throws: AgentError.visionFailure("Vision returned invalid text observations")) {
        try await provider.analyze(image: ImageInput(data: data))
      }
    }
  }

  @Test func invalidInputNeverReachesOCR() async throws {
    let provider = try AppleVisionProvider(textRecognition: Options()) { _, _ in
      Issue.record("Invalid image reached OCR")
      return []
    }
    await #expect(
      throws: AgentError.visionFailure("Image is empty or exceeds the encoded byte limit")
    ) {
      try await provider.analyze(image: ImageInput(data: Data()))
    }
  }

  @Test func typedErrorsAndCancellationSurviveTheOCRRoute() async throws {
    let data = try AppleVisionProviderTests.imageData()
    let broken = try AppleVisionProvider(textRecognition: Options()) { _, _ in
      throw CocoaError(.fileReadCorruptFile)
    }
    await #expect(throws: AgentError.visionFailure("Text recognition failed")) {
      try await broken.analyze(image: ImageInput(data: data))
    }
    let typed = try AppleVisionProvider(textRecognition: Options()) { _, _ in
      throw AgentError.visionFailure("scripted OCR failure")
    }
    await #expect(throws: AgentError.visionFailure("scripted OCR failure")) {
      try await typed.analyze(image: ImageInput(data: data))
    }
    let cancelled = try AppleVisionProvider(textRecognition: Options()) { _, _ in
      throw CancellationError()
    }
    await #expect(throws: AgentError.cancelled) {
      try await cancelled.analyze(image: ImageInput(data: data))
    }
    let late = try AppleVisionProvider(textRecognition: Options()) { _, _ in
      withUnsafeCurrentTask { $0?.cancel() }
      return [Self.line("Late")]
    }
    await #expect(throws: AgentError.cancelled) {
      try await Task { try await late.analyze(image: ImageInput(data: data)) }.value
    }
  }

  static func imageData(lines: [String]) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: 800, height: 300, bitsPerComponent: 8, bytesPerRow: 3200,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 300))
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
        "Helvetica" as CFString, 40, nil),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ]
    for (index, text) in lines.enumerated() {
      context.textPosition = CGPoint(x: 40, y: 220 - index * 70)
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes))
      CTLineDraw(line, context)
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
struct AppleVisionOCRNativeTests {
  @Test(arguments: [AppleVisionProvider.TextRecognitionConfiguration.Level.accurate, .fast])
  func generatedTextAndBlankImagesRunThroughNativeOCR(
    level: AppleVisionProvider.TextRecognitionConfiguration.Level
  ) async throws {
    let options = try AppleVisionProvider.TextRecognitionConfiguration(
      level: level, languages: ["en-US"],
      automaticallyDetectsLanguage: false, usesLanguageCorrection: false)
    let provider = try AppleVisionProvider(textRecognition: options)
    let data = try AppleVisionOCRTests.imageData(lines: ["LOCAL OCR TEST", "TOTAL 42.50"])
    let result = try await provider.analyze(image: ImageInput(data: data))
    #expect(result.text.contains("LOCAL OCR TEST"))
    #expect(result.text.contains("42.50"))
    #expect(
      result.recognizedText.allSatisfy { $0.boundingBox.width > 0 && $0.boundingBox.height > 0 })
    let blank = try AppleVisionOCRTests.imageData(lines: [])
    #expect(try await provider.analyze(image: ImageInput(data: blank)).text.isEmpty)
  }

  @Test func defaultRecognitionOptionsWorkOnGeneratedEnglish() async throws {
    let provider = try AppleVisionProvider(textRecognition: .init())
    let data = try AppleVisionOCRTests.imageData(lines: ["LOCAL OCR TEST"])
    #expect(
      try await provider.analyze(image: ImageInput(data: data)).text.contains("LOCAL OCR TEST"))
  }

  @Test func unsupportedLanguageFailsExplicitly() async throws {
    let options = try AppleVisionProvider.TextRecognitionConfiguration(languages: ["zz-ZZ"])
    let provider = try AppleVisionProvider(textRecognition: options)
    let data = try AppleVisionOCRTests.imageData(lines: ["LOCAL OCR TEST"])
    await #expect(throws: AgentError.visionFailure("Requested OCR language is unsupported")) {
      try await provider.analyze(image: ImageInput(data: data))
    }
  }
}
