import Foundation
import ImageIO
import LocalAgentKitCore
import Vision

extension AppleVisionProvider {
  /// Selection of built-in detectors. Supported categories are people, cats and dogs.
  public struct ObjectDetectionConfiguration: Sendable, Hashable {
    /// Native detector families available without an app-supplied model.
    public enum Target: Sendable, Hashable {
      /// Detect people with the native full-body rectangle request.
      case people
      /// Recognize cats and dogs with revision 2 of the native animal request.
      case animals
    }

    /// Requested detector families. Each is invoked at most once per analysis.
    public let targets: Set<Target>
    /// Inclusive cutoff on native observation confidence, separate from label confidence.
    public let minimumConfidence: Float
    /// Maximum returned objects, selected by confidence with source-order ties.
    public let resultLimit: Int

    /// Creates a detector configuration. Targets must be nonempty, the confidence finite
    /// in zero through one, and the result limit positive.
    public init(
      targets: Set<Target> = [.people, .animals],
      minimumConfidence: Float = 0, resultLimit: Int = 20
    ) throws {
      guard !targets.isEmpty, minimumConfidence.isFinite,
        (0...1).contains(minimumConfidence), resultLimit > 0
      else {
        throw AgentError.invalidConfiguration(
          .invalidLimit("Invalid object detection configuration"))
      }
      self.targets = targets
      self.minimumConfidence = minimumConfidence
      self.resultLimit = resultLimit
    }

    func select(_ observations: [VisionObjectObservation]) throws -> [VisionObjectObservation] {
      for observation in observations {
        try Task.checkCancellation()
        guard observation.confidence.isFinite, (0...1).contains(observation.confidence),
          observation.boundingBox.isValidNormalizedRegion, !observation.labels.isEmpty,
          observation.labels.allSatisfy({
            !$0.identifier.isEmpty && $0.confidence.isFinite && (0...1).contains($0.confidence)
          })
        else {
          throw AgentError.visionFailure("Vision returned invalid object observations")
        }
      }
      return Array(
        observations.enumerated()
          .filter { $0.element.confidence >= minimumConfidence }
          .sorted {
            $0.element.confidence == $1.element.confidence
              ? $0.offset < $1.offset : $0.element.confidence > $1.element.confidence
          }
          .prefix(resultLimit)
          .map(\.element))
    }
  }

  static func detectObjects(
    _ image: ImageInput, configuration: ObjectDetectionConfiguration
  ) async throws -> [VisionObjectObservation] {
    let orientation = image.orientation.flatMap {
      CGImagePropertyOrientation(rawValue: $0.rawValue)
    }
    var objects: [VisionObjectObservation] = []
    if configuration.targets.contains(.people) {
      try Task.checkCancellation()
      var request = DetectHumanRectanglesRequest(.revision2)
      request.upperBodyOnly = false
      let observations = try await request.perform(on: image.data, orientation: orientation)
      try Task.checkCancellation()
      objects += observations.map {
        VisionObjectObservation(
          labels: [.init(identifier: "person", confidence: $0.confidence)],
          confidence: $0.confidence, boundingBox: box($0.boundingBox))
      }
    }
    if configuration.targets.contains(.animals) {
      try Task.checkCancellation()
      let observations = try await RecognizeAnimalsRequest(.revision2).perform(
        on: image.data, orientation: orientation)
      try Task.checkCancellation()
      objects += observations.map {
        VisionObjectObservation(
          labels: $0.labels.map {
            VisionClassification(identifier: $0.identifier, confidence: $0.confidence)
          },
          confidence: $0.confidence, boundingBox: box($0.boundingBox))
      }
    }
    return objects
  }

  private static func box(_ rect: NormalizedRect) -> VisionBoundingBox {
    VisionBoundingBox(
      x: Double(rect.origin.x), y: Double(rect.origin.y),
      width: Double(rect.width), height: Double(rect.height))
  }
}

extension VisionBoundingBox {
  var isValidNormalizedRegion: Bool {
    [x, y, width, height].allSatisfy { $0.isFinite && (0...1).contains($0) }
      && width > 0 && height > 0 && x + width <= 1 && y + height <= 1
  }
}
