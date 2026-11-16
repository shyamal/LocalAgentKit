import AVFAudio
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import LocalAgentKitCore
import LocalAgentKitProviders
import Speech

struct WorkloadFixture: Decodable {
  let version: Int
  let imageWidth: Int
  let imageHeight: Int
  let imageText: String
  let font: String
  let fontSize: Double
  let textX: Double
  let textY: Double
  let speechText: String
  let locale: String
  let pathOrder: [ResourcePath]
  let secondsPerPhase: Int
  let batterySecondsPerPhase: Int
  let intervalMilliseconds: Int
}

struct NativeWorkloads: Sendable {
  let workloads: [ResourceWorkload]
  let metadata: [String: String]

  static func prepare(_ fixture: WorkloadFixture, digest: String) async throws -> Self {
    let image = try imageData(fixture)
    let ocr = try AppleVisionProvider(textRecognition: .init(languages: [fixture.locale]))
    let voice = AVSpeechSynthesisVoice.speechVoices().filter {
      $0.identifier.hasPrefix("com.apple.") && !$0.voiceTraits.contains(.isPersonalVoice)
        && $0.language == fixture.locale
    }.sorted { $0.identifier < $1.identifier }.first
    let synthesizer = try AppleSpeechSynthesizer(
      voiceIdentifier: voice?.identifier, timeout: .seconds(15))
    var speech: AudioOutput?
    var speechReason: String?
    do {
      speech = try await synthesizer.synthesize(text: fixture.speechText)
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      speechReason = String(describing: error)
    }
    let audio = speech.map { AudioInput(data: $0.data) }
    let recognizer = try AppleSpeechRecognizer(localeIdentifier: fixture.locale)
    let assets: String
    if SpeechTranscriber.isAvailable,
      let locale = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: fixture.locale))
    {
      let module = SpeechTranscriber(
        locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
      assets =
        await AssetInventory.status(forModules: [module]) == .installed
        ? "installed" : "not-installed"
    } else {
      assets = "unsupported"
    }
    try Task.checkCancellation()
    let speechFailure = speechReason
    let transcriptionUnavailable = assets == "installed" ? speechFailure : "Speech assets " + assets
    return Self(
      workloads: [
        ResourceWorkload(path: .idle) {},
        ResourceWorkload(path: .ocr) {
          let result = try await ocr.analyze(image: ImageInput(data: image))
          guard result.text.contains(fixture.imageText) else { throw FixtureFailure.ocrMismatch }
        },
        ResourceWorkload(path: .transcription, unavailableReason: transcriptionUnavailable) {
          guard let audio else { throw FixtureFailure.noAudio }
          let text = try await recognizer.transcribe(audio: audio)
          guard !text.isEmpty else { throw FixtureFailure.emptyTranscript }
        },
        ResourceWorkload(path: .synthesis, unavailableReason: speechFailure) {
          let output = try await synthesizer.synthesize(text: fixture.speechText)
          guard output.frameCount > 0 else { throw FixtureFailure.noAudio }
        },
      ],
      metadata: [
        "workloadSHA256": digest, "imageSHA256": sha(image),
        "audioSHA256": speech.map { sha($0.data) } ?? "unavailable",
        "voiceIdentifier": voice?.identifier ?? "unavailable", "recognitionAssets": assets,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "preparation":
          "Preparation excluded; synthesis warmed; first OCR/STT calls retained",
        "screenPolicy": "Foreground, idle timer disabled; brightness uncontrolled",
        "pathOrder": fixture.pathOrder.map(\.rawValue).joined(separator: ","),
      ])
  }

  static func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func imageData(_ fixture: WorkloadFixture) throws -> Data {
    guard fixture.version == 1, fixture.imageWidth == 800, fixture.imageHeight == 300,
      fixture.pathOrder == ResourcePath.allCases,
      let context = CGContext(
        data: nil, width: fixture.imageWidth, height: fixture.imageHeight,
        bitsPerComponent: 8, bytesPerRow: fixture.imageWidth * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw FixtureFailure.image }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: fixture.imageWidth, height: fixture.imageHeight))
    context.textPosition = CGPoint(x: fixture.textX, y: fixture.textY)
    let attributes: [NSAttributedString.Key: Any] = [
      .init(kCTFontAttributeName as String): CTFontCreateWithName(
        fixture.font as CFString, fixture.fontSize, nil),
      .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ]
    CTLineDraw(
      CTLineCreateWithAttributedString(
        NSAttributedString(string: fixture.imageText, attributes: attributes)), context)
    guard let image = context.makeImage() else { throw FixtureFailure.image }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { throw FixtureFailure.image }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw FixtureFailure.image }
    return data as Data
  }
}

private enum FixtureFailure: Error {
  case image, ocrMismatch, noAudio, emptyTranscript
}
