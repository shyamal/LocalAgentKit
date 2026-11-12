import Foundation

/// An encoded image supplied by the host, without UI or image-framework objects.
public struct ImageInput: Sendable, Hashable {
  /// EXIF orientation values, shared by image formats and platform decoders.
  public enum Orientation: UInt32, Sendable, Hashable, CaseIterable {
    /// Normal display orientation.
    case up = 1
    /// Normal orientation mirrored horizontally.
    case upMirrored = 2
    /// Rotated 180 degrees.
    case down = 3
    /// Rotated 180 degrees and mirrored horizontally.
    case downMirrored = 4
    /// Rotated left and mirrored horizontally.
    case leftMirrored = 5
    /// Rotated 90 degrees clockwise.
    case right = 6
    /// Rotated right and mirrored horizontally.
    case rightMirrored = 7
    /// Rotated 90 degrees counterclockwise.
    case left = 8
  }

  /// Encoded PNG, JPEG or another format supported by the selected provider.
  public let data: Data
  /// Overrides encoded orientation. Nil lets the provider use embedded metadata.
  public let orientation: Orientation?

  /// Supplies image bytes already authorized and read by the host.
  public init(data: Data, orientation: Orientation? = nil) {
    self.data = data
    self.orientation = orientation
  }
}

/// A provider's image category and its confidence, rather than an object location.
public struct VisionClassification: Sendable, Hashable {
  /// Provider-defined category identifier.
  public let identifier: String
  /// Confidence in the range zero through one; calibration depends on the provider.
  public let confidence: Float

  /// Creates a category prediction.
  public init(identifier: String, confidence: Float) {
    self.identifier = identifier
    self.confidence = confidence
  }
}

/// Framework-independent image analysis returned to the host.
public struct VisionResult: Sendable, Hashable {
  /// Image category predictions, in provider-defined order.
  public let classifications: [VisionClassification]

  /// Creates a result containing category predictions.
  public init(classifications: [VisionClassification] = []) {
    self.classifications = classifications
  }
}

/// Image analysis seam (FR-016). Concrete framework types stay in Providers.
public protocol VisionProvider: Sendable {
  /// Whether analysis needs network access. Hosts must honor this declaration before use.
  var requiresNetwork: Bool { get }
  /// Analyzes host-supplied image bytes. Errors are typed AgentError values.
  func analyze(image: ImageInput) async throws -> VisionResult
}

extension VisionProvider {
  /// Defaults to local image processing.
  public var requiresNetwork: Bool { false }
}
