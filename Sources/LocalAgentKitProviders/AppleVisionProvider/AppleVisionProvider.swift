import Foundation
import ImageIO
import LocalAgentKitCore
import Vision

/// Local classification, OCR and built-in object detection using Apple's Vision framework (FR-016).
/// Reads the first image in an encoded container. Does not read files or request camera access.
public struct AppleVisionProvider: VisionProvider {
  /// Local Vision inference has no network requirement.
  public let requiresNetwork = false
  private let maximumBytes: Int
  private let maximumPixels: Int
  private let process: @Sendable (ImageInput) async throws -> LocalAgentKitCore.VisionResult
  private let failureMessage: String

  /// Creates a classifier with encoded-byte, first-image pixel and result-count limits.
  /// Defaults allow 16 MiB, 24 million pixels and five category predictions.
  /// These limits bound accepted inputs; they are not peak-memory guarantees.
  public init(
    maximumBytes: Int = 16 * 1024 * 1024,
    maximumPixels: Int = 24_000_000, resultLimit: Int = 5
  ) throws {
    try self.init(
      maximumBytes: maximumBytes, maximumPixels: maximumPixels, resultLimit: resultLimit,
      classify: Self.classify)
  }

  init(
    maximumBytes: Int = 16 * 1024 * 1024, maximumPixels: Int = 24_000_000,
    resultLimit: Int = 5,
    classify: @escaping @Sendable (ImageInput) async throws -> [VisionClassification]
  ) throws {
    guard resultLimit > 0 else {
      throw AgentError.invalidConfiguration(.invalidLimit("Vision limits must be positive"))
    }
    try self.init(
      maximumBytes: maximumBytes, maximumPixels: maximumPixels,
      failureMessage: "Image classification failed"
    ) { image in
      let results = try await classify(image)
      guard
        results.allSatisfy({
          !$0.identifier.isEmpty && $0.confidence.isFinite && (0...1).contains($0.confidence)
        })
      else {
        throw AgentError.visionFailure("Vision returned invalid category predictions")
      }
      let sorted = results.sorted {
        $0.confidence == $1.confidence
          ? $0.identifier < $1.identifier : $0.confidence > $1.confidence
      }
      return LocalAgentKitCore.VisionResult(classifications: Array(sorted.prefix(resultLimit)))
    }
  }

  /// Creates an OCR-only provider with the supplied recognition and output limits.
  public init(
    textRecognition: TextRecognitionConfiguration, maximumBytes: Int = 16 * 1024 * 1024,
    maximumPixels: Int = 24_000_000
  ) throws {
    try self.init(
      textRecognition: textRecognition, maximumBytes: maximumBytes,
      maximumPixels: maximumPixels, recognize: Self.recognize)
  }

  init(
    textRecognition: TextRecognitionConfiguration, maximumBytes: Int = 16 * 1024 * 1024,
    maximumPixels: Int = 24_000_000,
    recognize:
      @escaping @Sendable (ImageInput, TextRecognitionConfiguration) async throws
      -> [VisionTextObservation]
  ) throws {
    try self.init(
      maximumBytes: maximumBytes, maximumPixels: maximumPixels,
      failureMessage: "Text recognition failed"
    ) { image in
      let observations = try await recognize(image, textRecognition)
      try textRecognition.validate(observations)
      return LocalAgentKitCore.VisionResult(recognizedText: observations)
    }
  }

  /// Creates a detector for the selected built-in categories, with confidence and result limits.
  public init(
    objectDetection: ObjectDetectionConfiguration, maximumBytes: Int = 16 * 1024 * 1024,
    maximumPixels: Int = 24_000_000
  ) throws {
    try self.init(
      objectDetection: objectDetection, maximumBytes: maximumBytes,
      maximumPixels: maximumPixels, detect: Self.detectObjects)
  }

  init(
    objectDetection: ObjectDetectionConfiguration, maximumBytes: Int = 16 * 1024 * 1024,
    maximumPixels: Int = 24_000_000,
    detect:
      @escaping @Sendable (ImageInput, ObjectDetectionConfiguration) async throws
      -> [VisionObjectObservation]
  ) throws {
    try self.init(
      maximumBytes: maximumBytes, maximumPixels: maximumPixels,
      failureMessage: "Object detection failed"
    ) { image in
      let observations = try await detect(image, objectDetection)
      return LocalAgentKitCore.VisionResult(
        detectedObjects: try objectDetection.select(observations))
    }
  }

  /// Creates a structured document recognizer with bounded output.
  public init(
    documentRecognition: DocumentRecognitionConfiguration, maximumBytes: Int = 16 * 1024 * 1024,
    maximumPixels: Int = 24_000_000
  ) throws {
    try self.init(
      documentRecognition: documentRecognition, maximumBytes: maximumBytes,
      maximumPixels: maximumPixels, recognizeDocuments: Self.recognizeDocuments)
  }

  init(
    documentRecognition: DocumentRecognitionConfiguration, maximumBytes: Int = 16 * 1024 * 1024,
    maximumPixels: Int = 24_000_000,
    recognizeDocuments:
      @escaping @Sendable (ImageInput, DocumentRecognitionConfiguration) async throws
      -> [VisionDocumentObservation]
  ) throws {
    try self.init(
      maximumBytes: maximumBytes, maximumPixels: maximumPixels,
      failureMessage: "Document recognition failed"
    ) { image in
      let documents = try await recognizeDocuments(image, documentRecognition)
      try documentRecognition.validate(documents)
      return LocalAgentKitCore.VisionResult(documents: documents)
    }
  }

  private init(
    maximumBytes: Int, maximumPixels: Int, failureMessage: String,
    process: @escaping @Sendable (ImageInput) async throws -> LocalAgentKitCore.VisionResult
  ) throws {
    guard maximumBytes > 0, maximumPixels > 0 else {
      throw AgentError.invalidConfiguration(.invalidLimit("Vision limits must be positive"))
    }
    self.maximumBytes = maximumBytes
    self.maximumPixels = maximumPixels
    self.failureMessage = failureMessage
    self.process = process
  }

  /// Runs the configured image-analysis operation on the admitted image.
  /// Resolves embedded EXIF orientation unless the host supplies an override. Malformed,
  /// oversized or undecodable inputs fail with visionFailure; cancellation discards late output.
  public func analyze(image: ImageInput) async throws -> LocalAgentKitCore.VisionResult {
    do {
      try Task.checkCancellation()
      guard !image.data.isEmpty, image.data.count <= maximumBytes else {
        throw AgentError.visionFailure("Image is empty or exceeds the encoded byte limit")
      }
      let options = [kCGImageSourceShouldCache: false] as CFDictionary
      guard let source = CGImageSourceCreateWithData(image.data as CFData, options),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
        width > 0, height > 0, width <= maximumPixels / height
      else {
        throw AgentError.visionFailure("Image is unreadable or exceeds the pixel limit")
      }
      let encodedOrientation =
        (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
      let orientation =
        image.orientation ?? ImageInput.Orientation(rawValue: encodedOrientation) ?? .up
      try Task.checkCancellation()
      let result = try await process(ImageInput(data: image.data, orientation: orientation))
      try Task.checkCancellation()
      return result
    } catch {
      if Task.isCancelled || error is CancellationError { throw AgentError.cancelled }
      if let error = error as? AgentError { throw error }
      throw AgentError.visionFailure(failureMessage)
    }
  }

  private static func classify(_ image: ImageInput) async throws -> [VisionClassification] {
    let observations = try await ClassifyImageRequest(.revision2).perform(
      on: image.data,
      orientation: image.orientation.flatMap { CGImagePropertyOrientation(rawValue: $0.rawValue) })
    return observations.map {
      VisionClassification(identifier: $0.identifier, confidence: $0.confidence)
    }
  }
}
