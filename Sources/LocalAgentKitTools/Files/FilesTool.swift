import Foundation
import LocalAgentKitCore

/// Read-only filename/metadata search inside directories explicitly supplied by the host (FR-008).
/// This tool never reads file contents, accepts model-supplied paths, or requests filesystem access.
public struct FilesTool: AgentTool {
  /// Registered action name.
  public let name = "search_files"
  /// Model guidance distinguishing filename search from document-content RAG.
  public let description =
    "Find files by filename in app-approved local folders. Returns names and metadata, not contents. Use search_documents for indexed document text."
  /// Required filename query and an optional constrained extension category.
  public let schema = ToolSchema(
    parameters: [
      "query": ToolParameter(
        .string, description: "Word or phrase in the filename, including extension."),
      "file_type": ToolParameter(
        .string, description: "Extension category to search.",
        allowedValues: FileKind.allCases.map(\.rawValue)),
    ], required: ["query"])
  /// Reads only metadata the app has already authorized within its supplied roots.
  public let permission = ToolPermission.readOnly
  /// The backing actor serializes scans; no mutation is performed.
  public let isParallelSafe = true
  /// Checks cancellation while enumerating and before returning; synchronous metadata calls may finish later.
  public let isCancellable = true
  private let searcher: LocalFileSearch

  /// Creates an explicitly scoped search. The host obtains any security-scoped access before use
  /// and keeps it active during execution. No default home/device-wide root is supplied.
  /// Limits are clamped to 1...10 results and 1...10,000 enumerated entries across all roots.
  /// - Throws: invalidConfiguration for empty roots or any non-file URL.
  public init(roots: [URL], limit: Int = 5, maxEntries: Int = 1000) throws {
    guard !roots.isEmpty, roots.allSatisfy(\.isFileURL) else {
      throw AgentError.invalidConfiguration(
        .unsupported("FilesTool requires explicit local directory URLs."))
    }
    self.searcher = LocalFileSearch(
      roots: roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() },
      limit: min(10, max(1, limit)), maxEntries: min(10_000, max(1, maxEntries)))
  }

  /// Returns bounded file metadata with an explicit partial-scan flag. Search is a localized
  /// case/diacritic-insensitive filename substring match; file_type uses extension heuristics.
  public func execute(arguments: ToolArguments) async throws -> ToolResult {
    if Task.isCancelled { throw AgentError.cancelled }
    let violations = schema.validate(arguments)
    guard violations.isEmpty else {
      throw AgentError.invalidArguments(tool: name, violations: violations)
    }
    guard let raw = arguments.string("query"),
      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AgentError.invalidArguments(tool: name, violations: [.missingRequired(path: "query")])
    }
    let kind = arguments.string("file_type").flatMap(FileKind.init(rawValue:)) ?? .any
    let result = try await searcher.search(
      query: raw.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
    if Task.isCancelled { throw AgentError.cancelled }
    let lines = result.files.enumerated().map { index, file in
      "[\(index + 1)] \(file.name) — root \(file.root + 1): \(file.path)"
    }
    let prefix =
      result.partial
      ? "Partial search: limits reached; results cover only the scanned portion.\n" : ""
    return ToolResult(
      callID: "", toolName: name,
      text: prefix
        + (lines.isEmpty
          ? "No matching files found in the scanned folders." : lines.joined(separator: "\n")),
      structured: .object([
        "matches": .array(result.files.map(\.json)), "is_partial": .bool(result.partial),
      ]),
      isEmpty: result.files.isEmpty)
  }
}

internal enum FileKind: String, CaseIterable, Sendable {
  case any, pdf, image, document, spreadsheet
  func matches(_ ext: String) -> Bool {
    switch self {
    case .any: true
    case .pdf: ext == "pdf"
    case .image:
      ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp", "svg", "avif"]
        .contains(ext)
    case .document:
      ["txt", "text", "md", "markdown", "rtf", "doc", "docx", "odt", "pages", "pdf"].contains(ext)
    case .spreadsheet: ["csv", "tsv", "xls", "xlsx", "ods", "numbers"].contains(ext)
    }
  }
}
