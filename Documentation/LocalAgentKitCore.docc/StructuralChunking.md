# Preserve document boundaries when chunking

`Chunker` defaults to `ChunkerConfiguration.Strategy.structureAware` (M3-03).
It packs complete paragraphs up to the character target within each available
ATX Markdown heading section. Headings begin new sections even if both sections
would fit in one chunk. Fenced code blocks and consecutive list lines stay together
when they fit. Paragraphs are joined with two newlines; internal line breaks remain.

```swift
let chunker = Chunker(configuration: .init(chunkSize: 800, overlap: 100))
let passages = chunker.chunk(document)
```

Oversized blocks use the original whole-word windows with approximate character
overlap. A single word longer than the target remains intact and exceeds that
target. Structural boundaries have no overlap: content from another paragraph or
section is not repeated just to fill the overlap budget. All chunks retain document
identity, title and sequential `chunkIndex` metadata. Sections additionally copy
the literal heading into `sectionHeading`; it is source content, not trusted policy.
Only the nearest heading is recorded, not a reconstructed hierarchy or citation.
Chunk IDs are generated afresh per call; text/boundary order is deterministic.

## Input and compatibility

Structure can only be preserved when it exists in `Document.text`. TXT/decoded
plain text retains line breaks. PDF extraction exposes text-layer order and page
separators, not visual headings, tables or layout. The existing Markdown cleanup
removes heading/fence markers. For a Markdown file through Tools, opt in to:

```swift
let document = try DocumentExtractor.load(
  contentsOf: authorizedMarkdownURL, preserveMarkdownStructure: true)
try await pipeline.ingest(document)
```

For raw Markdown in memory, pass it as plain text (the default) to the extractor.
The Core chunker does not read files, invoke a model or import PDFKit.
To retain the preceding whitespace-normalizing windows, use:

```swift
let legacy = Chunker(configuration: .init(
  chunkSize: 800, overlap: 100, strategy: .wordAligned))
```

Existing initializers remain source compatible, but the default chunk boundaries
change for structured documents. Rebuild stored embeddings if changing strategy;
this is not an automatic reindex or retrieval-quality guarantee. Invalid sizes or
overlaps yield no chunks; validate `configuration.issue` before ingestion.
Blank input yields none. CRLF/CR line endings normalize to LF in structure mode,
and outer block whitespace is trimmed.

## Heuristic limits

This is not a full Markdown parser or sentence segmenter. ATX headings require
one to six `#` markers at the start of a line followed by whitespace; indented and
Setext headings are not recognized. Backtick/tilde runs of at least three open a
fence, with matching-character closing runs at least as long followed only by
whitespace. Unclosed fences run to the end. Headings inside a fence do not form
sections, and blank lines there remain text. Oversized fences/lists can be split
by the fallback, so syntactically complete Markdown chunks are not promised.
No OCR, token-length guarantee, page citations or full document-layout recovery is
added. The runtime still budgets the assembled prompt using the model tokenizer.
Background ingestion and progress remain separate work (M3-06).
