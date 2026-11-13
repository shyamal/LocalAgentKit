import Foundation
import ImageIO
import LocalAgentKitCore
import Vision

extension AppleVisionProvider {
  /// OCR configuration and bounds for returned text. Native recognition runs before output limits.
  public struct TextRecognitionConfiguration: Sendable, Hashable {
    /// Native recognition speed/accuracy selection.
    public enum Level: Sendable, Hashable {
      /// Uses the native accurate recognizer.
      case accurate
      /// Uses the native fast recognizer.
      case fast
    }

    /// Requested native recognition level.
    public let level: Level
    /// Prioritized BCP-47 identifiers. An empty array retains native language defaults.
    public let languages: [String]
    /// Allows the native recognizer to detect supported languages.
    public let automaticallyDetectsLanguage: Bool
    /// Enables the recognizer's language correction.
    public let usesLanguageCorrection: Bool
    /// Maximum returned text regions; exceeding the limit fails the operation.
    public let maximumObservations: Int
    /// Maximum Swift characters, including inserted newlines; exceeding it fails the operation.
    public let maximumCharacters: Int

    /// Creates a recognition configuration. Limits must be positive and language hints nonblank.
    public init(
      level: Level = .accurate, languages: [String] = [],
      automaticallyDetectsLanguage: Bool = true, usesLanguageCorrection: Bool = true,
      maximumObservations: Int = 200, maximumCharacters: Int = 20_000
    ) throws {
      guard maximumObservations > 0, maximumCharacters > 0,
        languages.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      else {
        throw AgentError.invalidConfiguration(.invalidLimit("Invalid OCR limits or language hints"))
      }
      self.level = level
      self.languages = languages
      self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
      self.usesLanguageCorrection = usesLanguageCorrection
      self.maximumObservations = maximumObservations
      self.maximumCharacters = maximumCharacters
    }

    func validate(_ observations: [VisionTextObservation]) throws {
      guard observations.count <= maximumObservations else {
        throw AgentError.visionFailure("Recognized text exceeds the observation limit")
      }
      var size = 0
      for (index, observation) in observations.enumerated() {
        try Task.checkCancellation()
        let box = observation.boundingBox
        guard !observation.text.isEmpty, observation.confidence.isFinite,
          (0...1).contains(observation.confidence),
          box.isValidNormalizedRegion
        else {
          throw AgentError.visionFailure("Vision returned invalid text observations")
        }
        let separator = index == 0 ? 0 : 1
        guard separator <= maximumCharacters - size else {
          throw AgentError.visionFailure("Recognized text exceeds the character limit")
        }
        size += separator
        let count = observation.text.count
        guard count <= maximumCharacters - size else {
          throw AgentError.visionFailure("Recognized text exceeds the character limit")
        }
        size += count
      }
    }
  }

  static func recognize(
    _ image: ImageInput, configuration: TextRecognitionConfiguration
  ) async throws -> [VisionTextObservation] {
    var request = RecognizeTextRequest(.revision3)
    request.recognitionLevel = configuration.level == .accurate ? .accurate : .fast
    request.automaticallyDetectsLanguage = configuration.automaticallyDetectsLanguage
    request.usesLanguageCorrection = configuration.usesLanguageCorrection
    if !configuration.languages.isEmpty {
      let languages = configuration.languages.map { Locale.Language(identifier: $0) }
      guard languages.allSatisfy({ request.supportedRecognitionLanguages.contains($0) }) else {
        throw AgentError.visionFailure("Requested OCR language is unsupported")
      }
      request.recognitionLanguages = languages
    }
    let observations = try await request.perform(
      on: image.data,
      orientation: image.orientation.flatMap { CGImagePropertyOrientation(rawValue: $0.rawValue) })
    try Task.checkCancellation()
    return observations.compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let box = observation.boundingBox
      return VisionTextObservation(
        text: candidate.string, confidence: candidate.confidence,
        boundingBox: VisionBoundingBox(
          x: Double(box.origin.x), y: Double(box.origin.y),
          width: Double(box.width), height: Double(box.height)))
    }
  }
}
