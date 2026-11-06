# Extract documents through one entry point

Use ``DocumentExtractor`` for PDF, UTF-8 TXT/Markdown files and text already in
memory (FR-013, M3-02). Every path returns Core's `Document`, ready for the existing
`RetrievalPipeline`; PDFKit stays outside Core and Runtime.

```swift
import LocalAgentKitCore
import LocalAgentKitTools

let document = try DocumentExtractor.load(contentsOf: authorizedFileURL)
try await pipeline.ingest(document)

let pasted = try DocumentExtractor.load(text: pastedText, title: "Meeting notes")
let markdown = try DocumentExtractor.load(
  text: markdownSource, title: "Preparation", format: .markdown)
```

File dispatch uses the case-insensitive extension: `.pdf`, `.txt`, `.text`, `.md`
and `.markdown`. Set `preserveMarkdownStructure: true` when loading Markdown files
to retain heading/fence markers for the default structure-aware chunker. Memory
Markdown can be passed as plain text to retain its source. The default file behavior
still applies light Markdown cleanup. There is no MIME/content sniffing, HTML/RTF conversion or remote
URL fetching. Files must be regular local files; hosts own picker/security-scoped
access and provider-backed file availability. A local URL does not prove cloud
content is resident. Filenames without extensions become document titles; memory
input preserves the supplied title. Plain text is preserved, and Markdown uses
Core `DocumentLoader`'s existing light cleanup, not a full Markdown parser or
HTML sanitizer. Empty text files and memory input remain valid empty documents;
PDFs without extractable text fail. Extracted text and titles remain untrusted.

## Limits and cancellation

```swift
let document = try DocumentExtractor.load(
  contentsOf: authorizedFileURL, password: suppliedPDFPassword,
  limits: .init(maximumBytes: 8 * 1024 * 1024, maximumPages: 100,
                maximumCharacters: 200_000))
```

The shared `PDFDocumentLoader.Limits` defaults are 32 MiB, 500 pages and two million
Swift characters. All values must be positive for every format. Byte/character
limits apply to every file; page limits apply only to PDFs. Text files are read in
bounded chunks, then decoded strictly as UTF-8. Text character limits apply before
Markdown cleanup, including its syntax. Memory input takes only a positive
`maximumCharacters` limit; byte/page budgets cannot bound a string already held
by the caller. Limits do not bound all native parser or string allocations.

PDF dispatch delegates password handling, copying restrictions, page separators
and text-layer semantics to ``PDFDocumentLoader``; see <doc:PDFIngestion>. The
password argument is ignored for non-PDF formats and never stored by extraction.
No OCR, page citations or visual-layout reconstruction is added.

Invalid formats, nonlocal/nonregular/missing files, malformed UTF-8, invalid or
exceeded limits and PDF failures throw `AgentError.retrievalFailure`. Cancellation
throws `AgentError.cancelled`, checked before work, between file reads and around
decoding/cleanup. It cannot interrupt native operations or string cleanup already
in progress. Extraction is synchronous; hosts choose its execution context.
Runtime’s explicit `IngestionJob` (M3-06) can invoke this loader through a lazy
`DocumentIngestionSource`, with cooperative cancellation and cumulative AgentEvent
snapshots. Hosts retain authorized file scope through job completion. The default Core chunker now prefers
paragraphs and available Markdown sections (M3-03).

Core `DocumentLoader.load(contentsOf:)` remains source compatible and keeps its
previous unbounded text-file behavior. Core-only hosts can also call its pure
`load(text:title:format:)` without importing Tools. Use the unified Tools loader
when shared file validation and limits are required. Extraction neither executes
tools nor changes permission gates, and adds no model/network operation or runtime
state.
