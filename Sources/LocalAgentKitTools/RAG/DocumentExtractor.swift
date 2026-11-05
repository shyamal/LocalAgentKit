import Foundation
import LocalAgentKitCore

/// Unified synchronous extraction into a Core `Document` (FR-013, M3-02).
/// Hosts own authorized file access, execution context and provider-backed file availability.
/// No ingestion job, OCR, model call or tool permission is implied by extraction.
public enum DocumentExtractor {
  /// Reads a local PDF, UTF-8 text or Markdown file, selected by case-insensitive extension.
  ///
  /// Supports `.pdf`, `.txt`, `.text`, `.md` and `.markdown`; there is no content sniffing.
  /// The filename without its extension becomes the title. PDF passwords and copying rules
  /// are handled by `PDFDocumentLoader`; `password` is ignored for text formats.
  /// Shared byte/character limits apply to all files; page limits apply only to PDFs.
  /// Text character limits apply before Markdown cleanup. Empty text files are preserved,
  /// while PDFs without a text layer fail. Limits must all be positive for every format.
  /// Cancellation is checked during reads and around decoding/cleanup, but cannot interrupt
  /// native parsing or string processing already in progress. Limits do not bound native allocations.
  /// - Throws: `AgentError.cancelled` or `.retrievalFailure` for invalid input, limits or decoding.
  public static func load(
    contentsOf url: URL, password: String? = nil,
    limits: PDFDocumentLoader.Limits = .init()
  ) throws -> Document {
    try validate(limits)
    guard url.isFileURL else {
      throw AgentError.retrievalFailure("Document extraction requires a local file")
    }
    let ext = url.pathExtension.lowercased()
    if ext == "pdf" {
      return try PDFDocumentLoader.load(contentsOf: url, password: password, limits: limits)
    }
    guard ["txt", "text", "md", "markdown"].contains(ext) else {
      throw AgentError.retrievalFailure("Unsupported document format")
    }
    let data = try DocumentFileReader.read(url, maximumBytes: limits.maximumBytes)
    try checkCancellation()
    guard let text = String(data: data, encoding: .utf8) else {
      throw AgentError.retrievalFailure("Could not decode document as UTF-8 text")
    }
    return try load(
      text: text, title: url.deletingPathExtension().lastPathComponent,
      format: ext == "md" || ext == "markdown" ? .markdown : .plainText,
      maximumCharacters: limits.maximumCharacters)
  }

  /// Extracts already-decoded plain text or Markdown without a file or temporary-file round trip.
  /// Preserves the supplied title and empty text. The positive character limit is applied to
  /// the input before cleanup; byte/page limits do not apply to an existing Swift string.
  /// - Throws: `AgentError.cancelled` or `.retrievalFailure` for invalid/exceeded character limits.
  public static func load(
    text: String, title: String, format: DocumentLoader.TextFormat = .plainText,
    maximumCharacters: Int = 2_000_000
  ) throws -> Document {
    try checkCancellation()
    guard maximumCharacters > 0, text.count <= maximumCharacters else {
      throw AgentError.retrievalFailure(
        "Document text exceeds its character limit or limit is invalid")
    }
    let document = DocumentLoader.load(text: text, title: title, format: format)
    try checkCancellation()
    return document
  }

  private static func validate(_ limits: PDFDocumentLoader.Limits) throws {
    try checkCancellation()
    guard limits.maximumBytes > 0, limits.maximumPages > 0, limits.maximumCharacters > 0 else {
      throw AgentError.retrievalFailure("Document limits must be positive")
    }
  }

  private static func checkCancellation() throws {
    if Task.isCancelled { throw AgentError.cancelled }
  }
}
