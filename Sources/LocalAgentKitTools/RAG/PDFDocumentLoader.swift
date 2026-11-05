import Foundation
import LocalAgentKitCore
import PDFKit

/// Extracts a local PDF's existing text layer into a Core `Document` (FR-013, M3-01).
///
/// Pages retain PDFKit's order and are separated by two newlines. Images, handwriting,
/// annotations and layout reconstruction are not OCR'd or interpreted. Image-only/blank
/// documents fail rather than silently producing an empty ingestion. Mixed documents
/// contain only their available text layers; empty pages preserve their separators.
/// The caller owns file-picker/security-scope access and chooses the execution context.
public enum PDFDocumentLoader {
  /// Explicit input/work limits. These do not bound PDFKit's internal parsing allocations.
  public struct Limits: Sendable {
    /// Maximum file bytes read; defaults to 32 MiB.
    public var maximumBytes: Int
    /// Maximum number of pages; defaults to 500.
    public var maximumPages: Int
    /// Maximum extracted Swift characters, including separators; defaults to two million.
    public var maximumCharacters: Int

    /// Creates limits; loading rejects nonpositive values as typed retrieval failures.
    public init(
      maximumBytes: Int = 32 * 1024 * 1024, maximumPages: Int = 500,
      maximumCharacters: Int = 2_000_000
    ) {
      self.maximumBytes = maximumBytes
      self.maximumPages = maximumPages
      self.maximumCharacters = maximumCharacters
    }
  }

  /// Reads a regular local `.pdf` file and extracts its copy-permitted text layer.
  ///
  /// The filename without its extension becomes the title. `password` is used only to
  /// unlock this in-memory PDF; the parameter is not stored or interpolated into diagnostics.
  /// This synchronous operation checks cancellation during reads and between pages;
  /// it cannot interrupt a PDFKit parse already in progress. Batch scheduling/progress
  /// are separate ingestion concerns (M3-06).
  ///
  /// - Throws: `AgentError.cancelled`, or `.retrievalFailure` for invalid limits, unsupported
  ///   URLs, unreadable/corrupt/locked/copy-restricted PDFs, exceeded limits or no text layer.
  public static func load(
    contentsOf url: URL, password: String? = nil, limits: Limits = Limits()
  ) throws -> Document {
    try checkCancellation()
    guard limits.maximumBytes > 0, limits.maximumPages > 0, limits.maximumCharacters > 0 else {
      throw AgentError.retrievalFailure("PDF limits must be positive")
    }
    guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else {
      throw AgentError.retrievalFailure("PDF loading requires a local .pdf file")
    }
    let data = try read(url, maximumBytes: limits.maximumBytes)
    try checkCancellation()
    guard let pdf = PDFDocument(data: data) else {
      throw AgentError.retrievalFailure("Could not decode PDF")
    }
    if let password { _ = pdf.unlock(withPassword: password) }
    guard !pdf.isLocked else {
      throw AgentError.retrievalFailure("PDF is locked; a valid password is required")
    }
    guard pdf.allowsCopying else {
      throw AgentError.retrievalFailure("PDF does not permit text copying")
    }
    try checkCancellation()
    let count = pdf.pageCount
    guard count > 0, count <= limits.maximumPages else {
      throw AgentError.retrievalFailure("PDF page count is empty or exceeds its limit")
    }
    var pages: [String] = []
    pages.reserveCapacity(count)
    var characters = 0
    var containsText = false
    for index in 0..<count {
      try checkCancellation()
      guard let page = pdf.page(at: index) else {
        throw AgentError.retrievalFailure("Could not read PDF page \(index + 1)")
      }
      let text = page.string ?? ""
      try checkCancellation()
      let separator = index == 0 ? 0 : 2
      let remaining = limits.maximumCharacters - characters
      let length = text.count
      guard separator <= remaining, length <= remaining - separator else {
        throw AgentError.retrievalFailure("PDF extracted text exceeds its character limit")
      }
      characters += separator + length
      containsText = containsText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      pages.append(text)
    }
    guard containsText else {
      throw AgentError.retrievalFailure("PDF has no extractable text layer; OCR was not performed")
    }
    try checkCancellation()
    return Document(
      title: url.deletingPathExtension().lastPathComponent,
      text: pages.joined(separator: "\n\n"))
  }

  private static func read(_ url: URL, maximumBytes: Int) throws -> Data {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else {
        throw AgentError.retrievalFailure("PDF input must be a regular local file")
      }
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      var data = Data()
      while true {
        try checkCancellation()
        let remaining = maximumBytes - data.count
        // Probe one byte past the limit, without overflowing at Int.max.
        let amount = remaining >= 65_536 ? 65_536 : remaining + 1
        guard let chunk = try file.read(upToCount: amount), !chunk.isEmpty else { return data }
        guard chunk.count <= remaining else {
          throw AgentError.retrievalFailure("PDF exceeds its byte limit")
        }
        data.append(chunk)
      }
    } catch let error as AgentError { throw error } catch {
      throw AgentError.retrievalFailure("Could not read PDF file")
    }
  }

  private static func checkCancellation() throws {
    if Task.isCancelled { throw AgentError.cancelled }
  }
}
