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

/// A rectangle normalized to the oriented image, with its origin at the lower-left corner.
public struct VisionBoundingBox: Sendable, Hashable {
  /// Horizontal origin in image-relative coordinates.
  public let x: Double
  /// Vertical origin in image-relative coordinates.
  public let y: Double
  /// Width relative to the image width.
  public let width: Double
  /// Height relative to the image height.
  public let height: Double

  /// Creates a normalized region. Providers validate their output before returning it.
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

/// One recognized region, retaining the provider's best text candidate and confidence.
public struct VisionTextObservation: Sendable, Hashable {
  /// Recognized text for this region.
  public let text: String
  /// Native recognition confidence in zero through one.
  public let confidence: Float
  /// Location in the oriented image.
  public let boundingBox: VisionBoundingBox

  /// Creates a recognized text region.
  public init(text: String, confidence: Float, boundingBox: VisionBoundingBox) {
    self.text = text
    self.confidence = confidence
    self.boundingBox = boundingBox
  }
}

/// One located object with native detection confidence and category predictions.
public struct VisionObjectObservation: Sendable, Hashable {
  /// Category predictions for this region. Their confidences are separate from detection confidence.
  public let labels: [VisionClassification]
  /// Native observation confidence, used for detector score filtering.
  public let confidence: Float
  /// Location relative to the oriented image, with a lower-left origin.
  public let boundingBox: VisionBoundingBox

  /// Creates an object region with its labels and detection confidence.
  public init(
    labels: [VisionClassification], confidence: Float, boundingBox: VisionBoundingBox
  ) {
    self.labels = labels
    self.confidence = confidence
    self.boundingBox = boundingBox
  }
}

/// Framework-independent image analysis returned to the host.
public struct VisionResult: Sendable, Hashable {
  /// Image category predictions, in provider-defined order.
  public let classifications: [VisionClassification]

  /// Text regions in provider observation order, which may differ from document reading order.
  public let recognizedText: [VisionTextObservation]
  /// Located object predictions in provider-defined order.
  public let detectedObjects: [VisionObjectObservation]
  /// Structured document observations in native order.
  public let documents: [VisionDocumentObservation]
  /// OCR region text followed by document transcripts, joined with newlines.
  public var text: String {
    (recognizedText.map(\.text) + documents.map(\.text)).joined(separator: "\n")
  }

  /// Creates an analysis result. Existing category-only construction remains available.
  public init(
    classifications: [VisionClassification] = [], recognizedText: [VisionTextObservation] = [],
    detectedObjects: [VisionObjectObservation] = [], documents: [VisionDocumentObservation] = []
  ) {
    self.classifications = classifications
    self.recognizedText = recognizedText
    self.detectedObjects = detectedObjects
    self.documents = documents
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
