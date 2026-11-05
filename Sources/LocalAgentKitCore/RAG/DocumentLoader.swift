import Foundation

/// Loads plain text and Markdown (FR-013). PDF text extraction is provided separately by
/// LocalAgentKitTools.PDFDocumentLoader so Core never imports PDFKit.
public enum DocumentLoader {
  private static let supportedExtensions: Set<String> = ["txt", "text", "md", "markdown"]

  /// - Throws: `.retrievalFailure` for an unsupported extension or unreadable/non-UTF-8 content.
  public static func load(contentsOf url: URL) throws -> Document {
    let ext = url.pathExtension.lowercased()
    guard supportedExtensions.contains(ext) else {
      throw AgentError.retrievalFailure("unsupported document format: .\(ext)")
    }
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
    else {
      throw AgentError.retrievalFailure("could not read \(url.lastPathComponent) as UTF-8 text")
    }
    let isMarkdown = ext == "md" || ext == "markdown"
    return Document(
      title: url.deletingPathExtension().lastPathComponent,
      text: isMarkdown ? stripMarkdown(text) : text)
  }

  /// A light pass that removes Markdown syntax noise — headers, emphasis markers, link brackets,
  /// code fences, list/quote markers — so an embedding sees prose rather than punctuation. Full
  /// Markdown parsing is unnecessary for retrieval quality at this scale.
  static func stripMarkdown(_ text: String) -> String {
    let lines = text.components(separatedBy: "\n").map(stripLinePrefix)
    let joined = lines.joined(separator: "\n")
    return stripInlineMarkers(joined)
  }

  private static func stripLinePrefix(_ line: String) -> String {
    var line = line
    // Headers (`#`, `##`, …), blockquotes (`>`), and list bullets (`-`, `*`, `+`), each followed
    // by whitespace.
    for prefix in ["#######", "######", "#####", "####", "###", "##", "#", ">", "-", "*", "+"] {
      if line.hasPrefix(prefix + " ") {
        line = String(line.dropFirst(prefix.count + 1))
        break
      }
    }
    // A fenced code block delimiter on its own line contributes nothing.
    if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { return "" }
    return line
  }

  private static func stripInlineMarkers(_ text: String) -> String {
    var result = text
    // Link/image syntax: keep the visible text, drop the URL. `![alt](url)` and `[text](url)`.
    while let range = result.range(of: #"!?\[([^\]]*)\]\(([^)]*)\)"#, options: .regularExpression) {
      let match = String(result[range])
      let inner = match.hasPrefix("![") ? String(match.dropFirst(2)) : String(match.dropFirst(1))
      let label = inner.prefix { $0 != "]" }
      result.replaceSubrange(range, with: label)
    }
    for marker in ["**", "__", "`"] {
      result = result.replacingOccurrences(of: marker, with: "")
    }
    // Single-character emphasis (`*italic*`, `_italic_`): scoped to a `marker...marker` pair
    // rather than stripped everywhere, so a bare `*` or `_` elsewhere (multiplication, filenames,
    // snake_case) is left alone.
    result = replaceEmphasis(result, pattern: #"\*([^*]+)\*"#)
    result = replaceEmphasis(result, pattern: #"_([^_]+)_"#)
    return result
  }

  private static func replaceEmphasis(_ text: String, pattern: String) -> String {
    var result = text
    while let range = result.range(of: pattern, options: .regularExpression) {
      let inner = String(result[range]).dropFirst().dropLast()
      result.replaceSubrange(range, with: inner)
    }
    return result
  }
}
