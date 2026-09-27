/// Chunk size and overlap, in characters (M1-RG-02). Character counts rather than tokens: Core
/// has no tokenizer, and a provider's own count is a better fit for the context budget anyway
/// (`ContextBudgeter` measures the assembled prompt, not individual chunks).
public struct ChunkerConfiguration: Sendable, Hashable {
  public var chunkSize: Int
  public var overlap: Int

  public init(chunkSize: Int = 800, overlap: Int = 100) {
    self.chunkSize = chunkSize
    self.overlap = overlap
  }

  public static let `default` = ChunkerConfiguration()

  public var issue: ConfigurationIssue? {
    if chunkSize < 1 { return .invalidLimit("chunkSize must be positive") }
    if overlap < 0 { return .invalidLimit("overlap must not be negative") }
    if overlap >= chunkSize { return .invalidLimit("overlap must be smaller than chunkSize") }
    return nil
  }
}

/// Splits a document's text into overlapping word-aligned chunks (M1-RG-02).
///
/// Packs whole words up to `chunkSize` characters, then starts the next chunk far enough back to
/// repeat about `overlap` characters of the previous one — so a sentence that lands on a chunk
/// boundary still appears whole in at least one chunk.
public struct Chunker: Sendable {
  public let configuration: ChunkerConfiguration

  public init(configuration: ChunkerConfiguration = .default) {
    self.configuration = configuration
  }

  public func chunk(_ document: Document) -> [DocumentChunk] {
    let words = document.text.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return [] }

    var chunks: [DocumentChunk] = []
    var start = 0
    var index = 0
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
      chunks.append(
        DocumentChunk(
          documentID: document.id, text: text,
          metadata: ["title": document.title, "chunkIndex": String(index)]))
      index += 1
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
}
