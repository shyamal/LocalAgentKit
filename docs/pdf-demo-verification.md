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
app was installed on the paired iPhone 15 Pro. iOS blocked the launch attempt because
the device was locked; device interaction and user-file answer correctness are not
yet verified. Existing user-local Xcode signing settings were preserved.

## Acceptance remaining

On an unlocked Apple Intelligence-capable iPhone, open Ask a PDF and select an
actual authorized downloaded text-layer PDF. Check indexing/progress, ask a question
with a known answer and compare visible excerpts and answer to the original. Replace
with another PDF (including the same filename), verify context isolation, cancel an
import and a question, then close/reopen. Reject blank/locked or over-limit PDFs
without a false ready state. Do not use simulator generation as device acceptance.

The current local embedding path has measured limitations and fallback can change
vector space; the prototype does not integrate MiniLM/Core AI (M3-11) or calibrate
answerability (M3-07). Empty retrieval is not the same as semantic absence, and
nonempty snippets may be unrelated. PDF layout/OCR/page citations, provider downloads,
OS background execution, secure erasure and resource/quality guarantees are not
claimed. File providers may download user selections outside SDK network policy.

M3-10 remains in progress until that real user-PDF check. The milestone exit is not
satisfied by generated-file tests, build/install success or scripted answers.
