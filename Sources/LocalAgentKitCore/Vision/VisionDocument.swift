/// A recognized table cell with inclusive row and column spans.
public struct VisionDocumentCell: Sendable, Hashable {
  /// Recognized cell text.
  public let text: String
  /// Inclusive native row indices.
  public let rowRange: ClosedRange<Int>
  /// Inclusive native column indices.
  public let columnRange: ClosedRange<Int>
  /// Region in the oriented image.
  public let boundingBox: VisionBoundingBox

  /// Creates a table cell without expanding merged cells.
  public init(
    text: String, rowRange: ClosedRange<Int>, columnRange: ClosedRange<Int>,
    boundingBox: VisionBoundingBox
  ) {
    self.text = text
    self.rowRange = rowRange
    self.columnRange = columnRange
    self.boundingBox = boundingBox
  }
}

/// A native table, retaining dimensions and recognized cells.
public struct VisionDocumentTable: Sendable, Hashable {
  /// Number of native table rows.
  public let rowCount: Int
  /// Number of native table columns.
  public let columnCount: Int
  /// Recognized cells in native row traversal order. Merged cells retain spans.
  public let cells: [VisionDocumentCell]
  /// Table region in the oriented image.
  public let boundingBox: VisionBoundingBox

  /// Creates a recognized table.
  public init(
    rowCount: Int, columnCount: Int, cells: [VisionDocumentCell], boundingBox: VisionBoundingBox
  ) {
    self.rowCount = rowCount
    self.columnCount = columnCount
    self.cells = cells
    self.boundingBox = boundingBox
  }
}

/// A document region with native transcript, paragraph grouping and table structure.
public struct VisionDocumentObservation: Sendable, Hashable {
  /// Full native transcript, including text also represented in tables or paragraphs.
  public let text: String
  /// Native title, when identified.
  public let title: String?
  /// Paragraph transcripts in native order.
  public let paragraphs: [String]
  /// Recognized tables.
  public let tables: [VisionDocumentTable]
  /// Native document confidence.
  public let confidence: Float
  /// Document region in the oriented image.
  public let boundingBox: VisionBoundingBox

  /// Creates a structured document observation.
  public init(
    text: String, title: String? = nil, paragraphs: [String] = [],
    tables: [VisionDocumentTable] = [], confidence: Float, boundingBox: VisionBoundingBox
  ) {
    self.text = text
    self.title = title
    self.paragraphs = paragraphs
    self.tables = tables
    self.confidence = confidence
    self.boundingBox = boundingBox
  }
}
