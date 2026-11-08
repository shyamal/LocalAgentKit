# User-PDF demo implementation (M3-10, partial)

Implemented 2026-11-06. The existing demo exposes a separate Ask a PDF sheet with
native PDF-only import, balanced security-scoped reads, bounded background indexing,
progress/cancellation, isolated in-memory context and visible source excerpts.
No SDK library implementation, runtime dependency or generated project reference
changes are required; the feature is contained in the existing demo source files.

The demo reuses DocumentExtractor/IngestionJob and the current embedding provider.
A deterministic planner performs one literal-query search plus one tool-free answer;
empty results complete without a model call. Context fitting remains active. The
PDF runtime registers only a read-only document search, with no notes/calendar or
write actions. Its turns/vectors are not checkpointed. Generation IDs prevent stale
imports from publishing state and force a new chat even for the same filename.

## Verified APIs and checks

Read installed SwiftUI swiftinterface for the single-selection fileImporter URL
result/allowedContentTypes API, UniformTypeIdentifiers UTCoreTypes.h for PDF, and
Foundation NSURL.h for start/stopAccessingSecurityScopedResource and balancing.
Existing SDK-verified PDFKit/CoreGraphics/CoreText APIs generate local test PDFs.
The actual picker UI compiles on iPhoneOS and macOS; no API was inferred solely
from a WWDC description.

All 23 demo functions pass, including eleven new PDF functions: generated text-layer
PDF search/answer context, one search/one model call and empty tools on answer
requests, bounded no-evidence completion, separate corpora, locked/blank/over-page
and over-byte failures, readiness only after indexing, failed replacements, same-name
identity, cancellation and stale-import rejection. Actor gates control races without
timing assumptions; models/embeddings are mocks and target files are generated.

The SDK strict build, 719 root functions, network-denied suite, 70 Python tests,
strict formatting (including demo files), layering and diff checks pass. Core/Runtime
coverage is 98.81% (2895/2930), down 0.06 percentage points from the preceding base
run: Core unchanged at 99.44% (889/894), Runtime 98.53% (2006/2036) versus 98.62%.
Neither coverage target's source changed; this reflects executed Runtime lines.

macOS, generic iOS and signed physical-iPhone builds succeed. Existing AppIntents
metadata/orientation diagnostics remain; no Swift warning was silenced. The signed
app was installed on the paired iPhone 15 Pro. The first launch was blocked by
the device lock. After unlocking on 2026-11-08, the app imported a user PDF and
displayed retrieved excerpts. The first summary reply contained only a passage
label. The PDF planner now supplies the labeled excerpts to the budgeted model in a dedicated
answer prompt. A regression test checks that the prompt retains text beyond the
shared workflow formatter’s clipping limit and that a label-only response shows
a generation failure message. All 24 demo tests pass with this change. Existing
user-local Xcode signing settings were preserved. The updated app was installed
and launched on the same iPhone. The user confirmed that the same-PDF summary
worked on retest.

## Acceptance remaining

On the iPhone, replace the selected PDF (including with one of the same filename)
and verify context isolation. Cancel an import and a question, then close and
reopen the sheet. Check that blank, locked and over-limit PDFs fail visibly.

The current local embedding path has measured limitations and fallback can change
vector space; the prototype does not integrate MiniLM/Core AI (M3-11) or calibrate
answerability (M3-07). Empty retrieval is not the same as semantic absence, and
nonempty snippets may be unrelated. PDF layout/OCR/page citations, provider downloads,
OS background execution, secure erasure and resource/quality guarantees are not
claimed. File providers may download user selections outside SDK network policy.

M3-10 remains in progress while these device checks are pending.
