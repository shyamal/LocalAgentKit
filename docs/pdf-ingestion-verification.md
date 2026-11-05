# PDF text ingestion verification (M3-01)

Verified 2026-11-05 against the installed Xcode 27.2 SDK. `PDFDocumentLoader` lives
in LocalAgentKitTools and returns only Core's Sendable `Document`. PDFKit never
enters Core or Runtime; the layering guard now rejects that import in either.
The Core text/Markdown loader continues rejecting PDFs, pending unified dispatch
in M3-02. Usage and the exact contract are in the PDFIngestion DocC guide.

## API and behavior evidence

Read PDFDocument.h/PDFPage.h for data initialization, page access/text, locking,
password unlock and `allowsCopying`. Read CGPDFContext.h/CGDataConsumer.h and
CoreText CTLine.h before generating local fixtures. A scratch snippet compiled
under Swift 6 complete concurrency checking created a one-page PDF and extracted
“Budget review preparation”; a separate compiled bitmap snippet verified the
image-only fixture's API. No Apple-framework overload was assumed without checking.

The implementation reads bounded chunks from regular local .pdf files before
creating PDFDocument from Data. It preserves PDFKit page order and joins pages
with two newlines, with filename-derived titles. Limits are configurable positive
integers: defaults 32 MiB bytes, 500 pages and two million Swift characters including
separators. It checks cancellation before/after native work and between reads/pages,
returning typed AgentError.cancelled; I/O, parse, permission and limit failures are
typed retrieval failures. The password parameter is not stored or interpolated into
the loader's own diagnostics, and unlock alone does not waive copying restrictions.

## Tests and checks

Twelve generated-fixture Swift test functions pass:

- Multi-page ordering, filename titles and exact separators.
- Byte boundary acceptance and one-byte-over rejection.
- Page and character limits, including Unicode grapheme counting and separators.
- Corrupt/missing/directory/unsupported-extension/remote input and invalid limits.
- Blank, mixed text/blank and actual image-only PDF behavior.
- Encrypted PDF: missing/wrong/correct password, plus reader copy denial.
- Typed pre-cancellation without publishing an empty document.
- Actual extraction into the existing mock embedding/vector ingest/retrieve path.
- A multi-read oversized input rejected at the byte limit before PDF parsing.

Tests use CoreGraphics/CoreText to create temporary PDFs rather than bundling
third-party documents or fonts. No model assets, personal data, network or physical
device are required. The corrupt-PDF case emits CoreGraphics' expected parser
message; it still returns the tested typed error and no success result.

Mechanical checks passed: warning-free Swift package build, all **647** default
Swift functions, network-disabled suite, existing example suites (four custom-tool,
twelve declared demo functions with optional fixture helper disabled, seven probe
functions), **62** Python tests, strict Swift formatting, layering and DocC with
8,302 internal references. Two new Python functions execute the real layering script
against temporary trees: PDFKit is rejected in each gated target and allowed in Tools.

Core/Runtime coverage is **98.72% (2632/2666)**, above 80% and 0.04 percentage points
below the preceding run. Core remains 99.17% (721/727; documentation-only edit),
Runtime is 98.56% (1911/1939) versus 98.61% before (one fewer executed line, unchanged
source). No coverage-target behavior or tests were changed to chase the variation.
The existing demo builds for generic iOS with signing disabled, compiling the new
Tools source against iPhoneOS 27.2. Its existing AppIntents metadata/orientation
build diagnostics remain; no new Swift warning was introduced or silenced.

## Limits and remaining work

This extracts an existing text layer, not OCR (M4-02). Mixed PDFs may omit visible
image text. Visual reading order, tables/layout, annotations and page-origin citations
are not reconstructed. The character limit is checked after native extraction;
these controls do not bound PDFKit's internal parse allocations. A native call in
progress cannot be forcibly interrupted. The file checks are not a filesystem jail.

No batching, progress event, background job, persistent vector store, unified format
extractor or real-user PDF UI is added: those are M3-02/03/05/06/10. There is no new
protocol requiring a mock and no new runtime state requiring an AgentEvent; this is
an explicit host loader. Permission tiers and runtime security ordering are unchanged.
No physical-iPhone PDF acceptance or complex/scanned layout quality is claimed.

## Reproduce

```bash
swift build
swift test --filter PDFDocumentLoaderTests
bash Scripts/check-coverage.sh
bash Scripts/check-offline-tests.sh
xcrun swift-format lint --configuration .swift-format --strict --recursive Sources Tests Package.swift
bash Scripts/check-layering.sh
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
python3 Scripts/build-docs.py
python3 Scripts/check-docs.py .build/documentation/LocalAgentKit.doccarchive
xcodebuild -project Examples/LocalAgentDemo/LocalAgentDemo.xcodeproj \
  -scheme LocalAgentDemo -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/lak-pdf-ios CODE_SIGNING_ALLOWED=NO build
```
