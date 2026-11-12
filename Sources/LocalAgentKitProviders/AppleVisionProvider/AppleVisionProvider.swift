import Foundation
import ImageIO
import LocalAgentKitCore
import Vision

/// Local image classification using Apple's Vision framework (FR-016).
/// Reads the first image in an encoded container. Does not read files or request camera access.
public struct AppleVisionProvider: VisionProvider {
  /// Local Vision inference has no network requirement.
  public let requiresNetwork = false
  private let maximumBytes: Int
  private let maximumPixels: Int
  private let resultLimit: Int
  private let classify: @Sendable (ImageInput) async throws -> [VisionClassification]

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
    guard maximumBytes > 0, maximumPixels > 0, resultLimit > 0 else {
      throw AgentError.invalidConfiguration(.invalidLimit("Vision limits must be positive"))
    }
    self.maximumBytes = maximumBytes
    self.maximumPixels = maximumPixels
    self.resultLimit = resultLimit
    self.classify = classify
  }

  /// Returns up to resultLimit categories, sorted by descending confidence then identifier.
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
      let results = try await classify(ImageInput(data: image.data, orientation: orientation))
      try Task.checkCancellation()
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
    } catch {
      if Task.isCancelled || error is CancellationError { throw AgentError.cancelled }
      if let error = error as? AgentError { throw error }
      throw AgentError.visionFailure("Image classification failed")
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
