# Unified document extraction verification (M3-02)

Verified 2026-11-05. `DocumentExtractor` in Tools accepts local PDF/TXT/Markdown
files or decoded plain text/Markdown and returns a Core `Document` for the existing
retrieval pipeline. Core gains a pure text overload and `TextFormat`; its existing
file API remains source compatible. No new protocol, mock requirement, observable
runtime state, permission tier or runtime dependency is introduced.

PDF dispatch calls the existing SDK-verified PDF loader; no new PDFKit API is used.
The internal bounded file reader is shared with UTF-8 loading, preserving existing
PDF error messages. All byte/page/character values must be positive. File dispatch
uses case-insensitive extensions, requires local regular files and rejects malformed
UTF-8. Text character budgets include Markdown syntax before cleanup; plain text
and caller-provided titles remain intact. Empty text is preserved, while PDFs
without text still fail. Memory strings use only a character budget.

Nine new Swift test functions cover all text aliases, file and memory semantics,
Markdown cleanup parity, title preservation, Unicode/exact byte and character
boundaries, invalid limits, unsupported/nonlocal/missing/nonregular/corrupt files,
empty text, multi-read rejection, typed cancellation, ingest/retrieve composition
with existing mocks, and PDF dispatch with password/limit forwarding. The preceding
PDF suite still covers page ordering, images, copy restrictions and encryption.

Validation: warning-free strict Swift build; 656 root Swift test functions and the
network-disabled suite; existing CustomTool/demo/EmbeddingProbe example suites;
62 Python tests; strict Swift formatting and layering; DocC public API validation
and static routes (8,360 internal references); generic iOS demo build with signing
disabled. Existing iOS metadata/orientation diagnostics remain.

Core/Runtime coverage is 98.84% (2637/2668), up 0.12 percentage points from M3-01.
Core is 99.18% (723/729), Runtime 98.71% (1914/1939). Runtime source is unchanged;
its variation reflects execution coverage rather than new runtime behavior.

## Limits

This synchronous host API does not schedule background work or emit progress
(M3-06). Cancellation is checked between reads and around cleanup; it cannot
interrupt native PDF parsing or string processing already underway. Limits do not
bound every native/string allocation. No OCR, layout reconstruction, page citations,
remote fetching, content sniffing, HTML sanitization or persistent vector storage
is added. Existing Core file loading retains its previous unbounded behavior;
callers needing unified validation/limits should use Tools. Hosts own file access,
execution context and provider-backed availability; local URLs alone do not prove
cloud files are resident. Text and titles remain untrusted model inputs.
No physical-device PDF acceptance is claimed (M3-10).

## Reproduce

```bash
swift build
swift test --filter 'DocumentExtractorTests|PDFDocumentLoaderTests'
bash Scripts/check-coverage.sh
bash Scripts/check-offline-tests.sh
xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests Package.swift
bash Scripts/check-layering.sh
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
python3 Scripts/build-docs.py
python3 Scripts/check-docs.py .build/documentation/LocalAgentKit.doccarchive
xcodebuild -project Examples/LocalAgentDemo/LocalAgentDemo.xcodeproj \
  -scheme LocalAgentDemo -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/lak-extraction-ios CODE_SIGNING_ALLOWED=NO build
```
