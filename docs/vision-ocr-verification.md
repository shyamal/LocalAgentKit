# Local OCR (M4-02)

Verified on 2026-11-12. AppleVisionProvider now offers a text-recognition
initializer using the existing VisionProvider protocol. The default initializer
continues to classify images. Both paths share byte/pixel preflight, first-image
selection, EXIF orientation resolution and cancellation/error handling.

## API and configuration

The installed Vision swiftinterface verifies RecognizeTextRequest revision3,
accurate/fast levels, supportedRecognitionLanguages, recognitionLanguages,
automatic language detection, language correction and async perform on encoded
Data. RecognizedTextObservation.topCandidates(1) supplies the best candidate's
string and confidence. Its normalized bounding box becomes a Core
VisionBoundingBox. Native headers specify a lower-left coordinate origin.

Core adds VisionTextObservation and VisionBoundingBox. VisionResult gains
recognizedText and newline-joined text, with empty defaults that preserve existing
category-only construction. The existing MockVisionProvider can return these
values through its original handler.

TextRecognitionConfiguration chooses the recognition level, prioritized language
hints, automatic detection and correction. Explicit languages are checked against
the native request's supported set after selecting the recognition level. An
unsupported language returns a typed vision failure. Empty hints retain the native
language defaults.

Output defaults to at most 200 regions and 20,000 Swift characters, including
joining newlines. Exceeding either limit fails the operation before a result is
returned. Character accounting uses Swift grapheme clusters and checks remaining
capacity before adding separators or content. Empty recognition returns empty
regions and text.

The adapter validates text, confidence and finite positive region bounds within
the normalized image. Region order is the provider's observation order. Complex
columns, tables, page citations, document hierarchy and structured extraction
remain later work. Coordinates describe the oriented image; UI overlays must
convert the origin as appropriate.

Native recognition completes before output validation. The output limits do not
bound native working memory or force interruption of work already underway.
Cancellation after native work discards its result. Shared input limits remain
16 MiB and 24 million first-image pixels by default.

## Verification

Seven new portable OCR functions cover configuration and orientation forwarding,
observation order, empty output, invalid settings, exact Unicode/newline bounds,
invalid text/confidence/geometry, image preflight, typed errors and cancellation.
Core and mock tests cover region preservation, joined text and protocol use.

Three opt-in native functions passed on macOS 26.6.2. The generated-text/blank-image
function ran both accurate and fast levels, recognizing “LOCAL OCR TEST” and
“TOTAL 42.50” from rendered PNG pixels. Default automatic-language options also
recognized the fixture. An unsupported language failed explicitly. The fixture
uses generated CoreText pixels and contains no user photograph. Run these checks
with LOCALAGENTKIT_DEVICE_TESTS=1 and --filter AppleVisionOCRNativeTests.

The warning-free package build, full default suite with 753 registered functions,
network-disabled suite, 24 demo functions, seven embedding-probe functions and
70 Python tests pass. Native tests remain opt-in. Strict formatting, layering,
DocC and the generic iOS build pass. The iOS build retains existing AppIntents
metadata and orientation warnings.

Core/Runtime coverage is 98.85% (2,923/2,957), unchanged at two decimal places from
M4-01. Core rises from 99.45% to 99.46% (916/921); Runtime remains 98.58%
(2,007/2,036).

The native fixtures verify execution, conversion and basic recognition only.
Receipt accuracy, multilingual quality, phone resource use and runtime attachment
orchestration require their own measurements and integration.
