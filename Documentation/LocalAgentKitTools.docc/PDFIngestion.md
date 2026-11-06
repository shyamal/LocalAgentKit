# Extract text from a PDF

Use ``PDFDocumentLoader`` from Tools for local PDF text layers (FR-013, M3-01).
The existing Core `DocumentLoader` continues to handle TXT/Markdown; PDFKit stays
outside Core and Runtime. Given an app-authorized file URL and configured local
embedding/vector providers:

```swift
import LocalAgentKitCore
import LocalAgentKitTools

let document = try PDFDocumentLoader.load(contentsOf: authorizedPDFURL)
let pipeline = RetrievalPipeline(embeddingProvider: embedding, vectorStore: vectors)
try await pipeline.ingest(document)
let passages = try await pipeline.retrieve(for: "What should I prepare?")
```

The caller owns file-picker/security-scoped access and provider-backed file availability
under its own policy. A file URL alone does not prove cloud content is resident.
The host runs this synchronous reader
in an appropriate execution context. Loading text does not execute tools or confer
permission. PDF contents and filenames remain untrusted input; normal runtime
permission gates still apply to any later model-produced tool calls.

## Text and page behavior

The result is a Core `Document`, titled from the filename without its extension.
PDFKit page order is retained and pages are separated by two newlines, including
empty pages. Text within a page follows PDFKit's extraction order; visual reading
order, columns, tables, annotations and layout are not reconstructed. Page-origin
citations are not added to the flat document or existing chunks.

This is text-layer extraction, not OCR. Image-only/blank files fail with a typed
retrieval error instead of silently ingesting nothing. A mixed text/image PDF
contains only its available text layers; extracting some text does not establish
that the entire visible document was captured. OCR is separate work (M4-02).
Unified file/memory dispatch is available through ``DocumentExtractor`` (M3-02);
see <doc:DocumentExtraction>. Core chunking now prefers the available paragraph
boundaries (M3-03), without reconstructing PDF layout.

## Limits and failures

The default limits are 32 MiB read bytes, 500 pages and two million Swift characters,
including page separators. All limits must be positive and can be configured:

```swift
let document = try PDFDocumentLoader.load(
  contentsOf: authorizedPDFURL,
  limits: .init(maximumBytes: 8 * 1024 * 1024, maximumPages: 100, maximumCharacters: 200_000))
```

The reader accepts regular local `.pdf` files (case-insensitive extension), reads
bounded chunks and probes past the byte budget before calling PDFKit. Invalid
URLs/formats, file access/decoding failures, locked files, copy restrictions,
exceeded limits and absent text layers throw `AgentError.retrievalFailure`.
The limits do not bound PDFKit's internal allocations: page text length can only
be checked after the native text extraction call returns.

For a host-supplied password, use `password:`. The value is passed to PDFKit's
unlock operation and is not persisted or interpolated into loader diagnostics.
An unlocked document must still permit copying; a reader password does not bypass
that restriction. The loader does not attempt password guessing or remove protection.

Cancellation throws `AgentError.cancelled`, checked before I/O, between reads,
after PDF decoding and around each page. It cannot interrupt a native PDFKit call
already running. This method does not start an ingestion job, emit progress,
schedule background work or persist vectors. Runtime’s `IngestionJob` (M3-06)
can call it lazily from an explicitly owned detached task; native parsing remains
non-interruptible. Vector persistence remains a separate provider concern.

## Verification

Generated PDF fixtures cover ordered multi-page/Unicode text, filename titles,
exact byte/page/character boundaries, a multi-chunk byte-budget failure, invalid
input/limits, blank/mixed/image-only pages, encrypted files, invalid/valid passwords,
copy denial, typed cancellation and actual ingest/retrieve composition using mocks.
No model assets, network, personal files or physical device are required by tests.
PDFKit/CoreGraphics/CoreText signatures were checked against the installed SDK and
a text/image fixture probe was compiled and run before implementation. An invalid
PDF test can emit CoreGraphics' parser diagnostic; that is an expected corrupt-input
case, not a Swift compiler warning or a swallowed extraction failure.
