import Foundation

/// Chunk size and overlap, in characters (M1-RG-02). Character counts rather than tokens: Core
/// has no tokenizer, and a provider's own count is a better fit for the context budget anyway
/// (`ContextBudgeter` measures the assembled prompt, not individual chunks).
public struct ChunkerConfiguration: Sendable, Hashable {
  /// Boundary selection used before applying the character target.
  public enum Strategy: Sendable, Hashable {
    /// Packs paragraphs within Markdown heading sections; oversized blocks fall back to words.
    case structureAware
    /// Original whitespace-normalizing, word-aligned windows with overlap.
    case wordAligned
  }

  /// Boundary strategy; defaults to preserving available document structure.
  public var strategy: Strategy

  /// Target chunk length in Swift characters; whole words can exceed it.
  public var chunkSize: Int
  /// Approximate overlap within word-aligned windows; structural boundaries are not overlapped.
  public var overlap: Int

  /// Creates chunking limits; inspect `issue` to validate them before ingestion.
  public init(chunkSize: Int = 800, overlap: Int = 100, strategy: Strategy = .structureAware) {
    self.strategy = strategy
    self.chunkSize = chunkSize
    self.overlap = overlap
  }

  /// Uses structural boundaries with an 800-character target and 100-character fallback overlap.
  public static let `default` = ChunkerConfiguration()

  /// The first invalid size or overlap constraint, or nil when valid.
  public var issue: ConfigurationIssue? {
    if chunkSize < 1 { return .invalidLimit("chunkSize must be positive") }
    if overlap < 0 { return .invalidLimit("overlap must not be negative") }
    if overlap >= chunkSize { return .invalidLimit("overlap must be smaller than chunkSize") }
    return nil
  }
}

/// Splits available document structure into bounded passages (M3-03).
/// Paragraphs, ATX Markdown sections and fenced blocks are preferred boundaries. Oversized
/// blocks use word windows; a single oversized word can exceed the target. This is a lexical
/// heuristic, not a Markdown parser, sentence tokenizer or reconstruction of PDF layout.
public struct Chunker: Sendable {
  /// The character target, overlap and boundary strategy used for chunking.
  public let configuration: ChunkerConfiguration

  /// Creates a chunker; `.wordAligned` retains the original whitespace-normalizing behavior.
  public init(configuration: ChunkerConfiguration = .default) {
    self.configuration = configuration
  }

  /// Returns passages with source identity, title and sequential chunk index metadata.
  /// Structural sections additionally record their literal heading in `sectionHeading`.
  /// Blank input or invalid configuration returns no chunks. IDs are newly generated per call.
  /// Structure mode normalizes line endings; overlap applies only inside oversized blocks.
  public func chunk(_ document: Document) -> [DocumentChunk] {
    guard configuration.issue == nil else { return [] }
    let pieces: [(text: String, heading: String?)]
    switch configuration.strategy {
    case .wordAligned:
      pieces = wordChunks(document.text).map { ($0, nil) }
    case .structureAware:
      pieces = structuredChunks(document.text)
    }
    return pieces.enumerated().map { index, piece in
      var metadata = ["title": document.title, "chunkIndex": String(index)]
      if let heading = piece.heading { metadata["sectionHeading"] = heading }
      return DocumentChunk(documentID: document.id, text: piece.text, metadata: metadata)
    }
  }

  private func wordChunks(_ text: String) -> [String] {
    let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return [] }

    var chunks: [String] = []
    var start = 0
    while start < words.count {
      var length = 0
      var end = start
      while end < words.count {
        let wordLength = words[end].count + (end > start ? 1 : 0)
        if length + wordLength > configuration.chunkSize && end > start { break }
        length += wordLength
        end += 1
      }
      let text = words[start..<end].joined(separator: " ")
      chunks.append(text)
      guard end < words.count else { break }

      // Step back from `end` by about `overlap` characters, word-aligned, but always progress by
      // at least one word so a huge overlap can't loop forever.
      var back = end - 1
      var backLength = 0
      while back > start, backLength < configuration.overlap {
        backLength += words[back].count + 1
        back -= 1
      }
      start = max(back + 1, start + 1)
    }
    return chunks
  }

  private func structuredChunks(_ text: String) -> [(text: String, heading: String?)] {
    var result: [(text: String, heading: String?)] = []
    var pending = ""
    var heading: String?
    func flush() {
      if !pending.isEmpty {
        result.append((pending, heading))
        pending = ""
      }
    }
    for item in blocks(text) {
      let block = item.text
      if let title = item.heading {
        flush()
        heading = title
      }
      if block.count > configuration.chunkSize {
        flush()
        result.append(contentsOf: wordChunks(block).map { ($0, heading) })
      } else if pending.isEmpty {
        pending = block
      } else if pending.count + 2 + block.count <= configuration.chunkSize {
        pending += "\n\n" + block
      } else {
        flush()
        pending = block
      }
    }
    flush()
    return result
  }

  private func blocks(_ text: String) -> [(text: String, heading: String?)] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var result: [(text: String, heading: String?)] = []
    var lines: [String] = []
    var fence: (marker: Character, count: Int)?
    func flush() {
      let block = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !block.isEmpty { result.append((block, nil)) }
      lines = []
    }
    for line in normalized.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let active = fence {
        lines.append(line)
        let run = trimmed.prefix { $0 == active.marker }
        if run.count >= active.count,
          trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
        {
          fence = nil
          flush()
        }
      } else if let marker = trimmed.first, marker == "`" || marker == "~",
        trimmed.prefix(while: { $0 == marker }).count >= 3
      {
        flush()
        fence = (marker, trimmed.prefix(while: { $0 == marker }).count)
        lines.append(line)
      } else if trimmed.isEmpty {
        flush()
      } else if atxHeading(line) != nil {
        flush()
        result.append((line, line))
      } else {
        lines.append(line)
      }
    }
    flush()
    return result
  }

  private func atxHeading(_ text: String) -> String? {
    guard !text.contains("\n") else { return nil }
    let marks = text.prefix { $0 == "#" }.count
    guard (1...6).contains(marks), text.dropFirst(marks).first?.isWhitespace == true else {
      return nil
    }
    return text
  }

}
