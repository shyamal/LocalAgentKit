# Structured document recognition (M4-04)

Verified on 2026-11-13. AppleVisionProvider adds an opt-in document-recognition
initializer through the existing VisionProvider seam. Native output becomes Core
document observations with transcripts, optional titles, paragraph groups,
confidence, normalized regions and tables containing inclusive cell spans.

## Native API evidence

The installed macOS 27.2 Vision swiftinterface declares RecognizeDocumentsRequest
revision1, its supported-language query and mutable text/barcode options. The
request is available from macOS/iOS 26, below the SDK's 26.4 deployment floor.
DocumentObservation.Container exposes text, title, paragraphs and tables. Table
rows/columns, cell content and rowRange/columnRange provide the structured data.
NormalizedRegion.boundingBox supplies an axis-aligned region.

The adapter requests one text candidate, disables barcode recognition, validates
explicit language hints against native support and analyzes the admitted image.
Existing byte/pixel bounds, EXIF/host orientation, error mapping and cancellation
checks are reused. Native framework types stay in Providers.

Identical appearances of a merged native cell are retained once in row traversal
order. The Core cell keeps its inclusive spans without expanding them to a dense
grid. Repeated conflicting positions fail validation. Sparse recognized cells,
empty text and native paragraph grouping remain as returned. Nested cell content
is represented by its transcript.

## Bounded output

DocumentRecognitionConfiguration defaults to eight documents, 256 paragraphs,
32 tables, 1,024 unique cells and 40,000 Swift characters. Limits are aggregate
across documents. Character counts include transcripts, titles, paragraphs and
cell text, including repeated representations and joining newlines. Exceeding a
limit fails before publishing a result.

Validation checks native confidence, normalized positive geometry, positive table
dimensions, unique cell positions and inclusive spans within table dimensions.
The existing mock returns the new Core values through its unchanged handler.

VisionResult.text retains OCR-region text followed by document transcripts, joined
with newlines. Existing category, object and OCR result construction uses empty
document defaults. A document-only result's text consists of its document
transcripts.

The provider analyzes the first encoded image. Native recognition and its
temporary allocations complete before output validation. Cancellation discards
late output but cannot forcibly stop native work already running.

## Verification

Six portable functions cover options/orientation forwarding, transcript and table
preservation, empty recognition, invalid settings, aggregate output and text
budgets, invalid confidence/geometry/spans/duplicate positions, preflight failures,
typed errors and cancellation. Additional Core/mock functions verify merged spans,
joined transcripts and the existing protocol contract.

Three opt-in native functions passed on macOS 26.6.2. A generated gridded invoice
was recognized as text and a table with multiple rows/columns and a TEA cell.
The same check passed with a blank final cell. A blank image produced no document
text, and an unsupported language failed explicitly. These fixtures verify native
execution and simple table structure; real-photo layout and extraction accuracy
remain unmeasured. Optional-title and merged-span preservation also have scripted
Core tests. Native merged-table quality remains unmeasured.

The first full coverage run stalled in the Runtime test helper. A process sample
showed the main run loop waiting without a useful test stack. The identified
helper and its parent test command were stopped. The unchanged full suite passed
on retry, as did the network-disabled suite. The cause of the stall remains
unestablished.

The warning-free SDK build, default suite with 774 registered functions, 24 demo
functions, seven embedding-probe functions, all 70 Python checks, strict formatting,
layering, DocC and generic iOS build pass. Native tests remain opt-in. Existing iOS
AppIntents metadata and orientation warnings remain.

Core/Runtime coverage is 98.93% (2,954/2,986), up 0.11 percentage points from
M4-03. Core is 99.47% (945/950); Runtime is 98.67% (2,009/2,036), with Runtime
source unchanged.

Semantic receipt fields and the on-device expense workflow remain M4-11. This
adapter extracts native document structure. List/barcode preservation, page
assembly and phone resource measurements remain future work.
