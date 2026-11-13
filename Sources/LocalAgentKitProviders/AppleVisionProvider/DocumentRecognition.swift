import Foundation
import ImageIO
import LocalAgentKitCore
import Vision

extension AppleVisionProvider {
  /// Native document recognition and aggregate output limits.
  public struct DocumentRecognitionConfiguration: Sendable, Hashable {
    /// Prioritized supported BCP-47 hints. Empty retains native language defaults.
    public let languages: [String]
    /// Maximum document regions returned in one analysis.
    public let maximumDocuments: Int
    /// Maximum paragraphs across all document regions.
    public let maximumParagraphs: Int
    /// Maximum tables across all document regions.
    public let maximumTables: Int
    /// Maximum unique table cells across all document regions.
    public let maximumCells: Int
    /// Maximum Swift characters across transcripts, titles, paragraphs and cell text,
    /// counting duplicated representations and document-joining newlines.
    public let maximumCharacters: Int

    /// Creates positive output limits and optional nonblank language hints.
    public init(
      languages: [String] = [], maximumDocuments: Int = 8, maximumParagraphs: Int = 256,
      maximumTables: Int = 32, maximumCells: Int = 1024, maximumCharacters: Int = 40_000
    ) throws {
      guard
        [maximumDocuments, maximumParagraphs, maximumTables, maximumCells, maximumCharacters]
          .allSatisfy({ $0 > 0 }),
        languages.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      else {
        throw AgentError.invalidConfiguration(
          .invalidLimit("Invalid document recognition limits or languages"))
      }
      self.languages = languages
      self.maximumDocuments = maximumDocuments
      self.maximumParagraphs = maximumParagraphs
      self.maximumTables = maximumTables
      self.maximumCells = maximumCells
      self.maximumCharacters = maximumCharacters
    }

    func validate(_ documents: [VisionDocumentObservation]) throws {
      guard documents.count <= maximumDocuments else {
        throw AgentError.visionFailure("Document recognition exceeds output limits")
      }
      var paragraphs = maximumParagraphs
      var tables = maximumTables
      var cells = maximumCells
      var characters = maximumCharacters
      func consume(_ text: String) throws {
        let count = text.count
        guard count <= characters else {
          throw AgentError.visionFailure("Document recognition exceeds output limits")
        }
        characters -= count
      }
      for (index, document) in documents.enumerated() {
        try Task.checkCancellation()
        guard document.confidence.isFinite, (0...1).contains(document.confidence),
          document.boundingBox.isValidNormalizedRegion,
          document.paragraphs.count <= paragraphs, document.tables.count <= tables
        else {
          throw AgentError.visionFailure("Invalid document structure or output limits")
        }
        paragraphs -= document.paragraphs.count
        tables -= document.tables.count
        if index > 0 { try consume("\n") }
        try consume(document.text)
        if let title = document.title { try consume(title) }
        for paragraph in document.paragraphs { try consume(paragraph) }
        for table in document.tables {
          try Task.checkCancellation()
          guard table.rowCount > 0, table.columnCount > 0,
            table.boundingBox.isValidNormalizedRegion, table.cells.count <= cells,
            Set(table.cells.map { CellPosition(rows: $0.rowRange, columns: $0.columnRange) }).count
              == table.cells.count
          else {
            throw AgentError.visionFailure("Invalid document table or output limits")
          }
          cells -= table.cells.count
          for cell in table.cells {
            try Task.checkCancellation()
            guard cell.boundingBox.isValidNormalizedRegion,
              cell.rowRange.lowerBound >= 0, cell.columnRange.lowerBound >= 0,
              cell.rowRange.upperBound < table.rowCount,
              cell.columnRange.upperBound < table.columnCount
            else {
              throw AgentError.visionFailure("Invalid document cell span or geometry")
            }
            try consume(cell.text)
          }
        }
      }
    }
  }

  private struct CellPosition: Hashable {
    let rows: ClosedRange<Int>
    let columns: ClosedRange<Int>
  }

  static func recognizeDocuments(
    _ image: ImageInput, configuration: DocumentRecognitionConfiguration
  ) async throws -> [VisionDocumentObservation] {
    var request = RecognizeDocumentsRequest(.revision1)
    request.barcodeDetectionOptions.enabled = false
    request.textRecognitionOptions.maximumCandidateCount = 1
    if !configuration.languages.isEmpty {
      let languages = configuration.languages.map { Locale.Language(identifier: $0) }
      guard languages.allSatisfy({ request.supportedRecognitionLanguages.contains($0) }) else {
        throw AgentError.visionFailure("Requested document language is unsupported")
      }
      request.textRecognitionOptions.recognitionLanguages = languages
    }
    let observations = try await request.perform(
      on: image.data,
      orientation: image.orientation.flatMap { CGImagePropertyOrientation(rawValue: $0.rawValue) })
    try Task.checkCancellation()
    return try observations.map { observation in
      try Task.checkCancellation()
      let document = observation.document
      let tables = try document.tables.map { table in
        var seen: Set<VisionDocumentCell> = []
        var cells: [VisionDocumentCell] = []
        for row in table.rows {
          for cell in row {
            try Task.checkCancellation()
            let value = VisionDocumentCell(
              text: cell.content.text.transcript, rowRange: cell.rowRange,
              columnRange: cell.columnRange,
              boundingBox: documentBox(cell.content.boundingRegion))
            if seen.insert(value).inserted { cells.append(value) }
          }
        }
        return VisionDocumentTable(
          rowCount: table.rows.count, columnCount: table.columns.count,
          cells: cells, boundingBox: documentBox(table.boundingRegion))
      }
      return VisionDocumentObservation(
        text: document.text.transcript, title: document.title?.transcript,
        paragraphs: document.paragraphs.map(\.transcript), tables: tables,
        confidence: observation.confidence, boundingBox: documentBox(document.boundingRegion))
    }
  }

  private static func documentBox(_ region: NormalizedRegion) -> VisionBoundingBox {
    let rect = region.boundingBox
    return VisionBoundingBox(
      x: Double(rect.origin.x), y: Double(rect.origin.y),
      width: Double(rect.width), height: Double(rect.height))
  }
}
