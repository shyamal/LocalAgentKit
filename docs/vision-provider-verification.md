# Vision provider foundation (M4-01)

M4-02 extends this foundation with opt-in OCR. See
[local OCR verification](vision-ocr-verification.md) for the current text-recognition
API, configuration and native checks. M4-03 adds built-in people/cat/dog detection;
see [object detection verification](vision-object-detection-verification.md).

Verified on 2026-11-12. Core now defines VisionProvider, encoded ImageInput with
EXIF orientation, VisionClassification and VisionResult. AppleVisionProvider in
Providers classifies a local image using Vision. MockVisionProvider in Testing
records inputs and supplies scripted results or failures.

The initial analysis operation returns image categories. OCR, object locations,
document understanding and runtime image attachments remain M4-02/03/04/07.
M4-03 is partially implemented because classification is already supplied here.

## Native API evidence

The installed macOS 27.2 Vision swiftinterface declares ClassifyImageRequest,
revision2, ClassificationObservation.identifier/confidence and the async
perform(on: Data, orientation:) overload. It is available from macOS 15 and iOS 18,
below this package's 26.4 floor. ImageIO headers confirm encoded-data sources,
first-image properties, dimensions and orientation metadata.

The adapter creates a request per call and translates the observations into Core
values. All native image and request types stay in Providers. The generic iOS
demo build passes with the new adapter, and the opt-in native test completed on
macOS 26.6.2 using an 8 × 4 generated TIFF. It returned nonempty finite categories
within the configured result limit. This checks native execution and conversion;
it does not measure classification accuracy on photographs or receipts.

## Behavior and limits

Input is host-authorized encoded data. There is no URL loading, camera capture or
photo-library permission request in the provider. Embedded EXIF orientation is used
unless the host supplies an override. The first image is analyzed for containers
with multiple images.

Accepted input defaults to 16 MiB encoded bytes and 24 million pixels. Dimensions
are checked using division before multiplication could overflow. Malformed,
empty and oversized inputs fail before inference. These are admission bounds,
not native decoding or process peak-memory bounds.

The provider validates nonempty category identifiers and finite confidences in
zero through one, then returns the top five by descending confidence with
identifier ordering for ties. An empty category result is allowed. The confidence
values are native model output with no application-specific calibration.

AgentError.visionFailure represents native or decoding failure, with a
human-readable description. Cancellation is checked before work, after metadata
reading and after native inference. A late result from an uncooperative operation
is discarded. Already-running native decoding or inference cannot be forcibly
interrupted by these checks.

The Apple adapter declares local processing. Hosts invoking other providers
directly must honor requiresNetwork and obtain image-access authorization.
The runtime does not yet accept VisionProvider or image attachments; that
configuration and policy integration is M4-07. This standalone provider adds no
runtime event, third-party dependency, or model call.

## Verification

Three Core functions cover orientation, value preservation, error copy and the
protocol default. Three mock functions cover input recording, scripted values,
typed and foreign errors, and cancellation. Six portable adapter functions cover
preflight boundaries, metadata/override orientation, output validation and sorting,
error translation and cancellation. A seventh adapter function is the explicit
native opt-in and stays disabled in the default hardware-independent suite.

The package builds warning-free. The first coverage run's Providers process
terminated with signal 11. Its crash report shows EXC_BAD_ACCESS in
NSSQLEntity_DerivedAttributesExtension._generateTriggerSQL during Core Data store
loading. The unchanged full suite passed on retry, as did the network-disabled
suite. No source or test configuration was changed between those runs.

The default suite contains 741 registered functions, including gated native
tests. Strict formatting, layering, all 70 Python checks, DocC and the generic iOS
build pass. Existing iOS AppIntents metadata and orientation warnings remain.
The native opt-in was run separately with LOCALAGENTKIT_DEVICE_TESTS=1 and
--filter AppleVisionNativeTests.

Core/Runtime coverage is 98.85% (2,910/2,944), up 0.01 percentage points from
M3-12. Core is 99.45% (903/908), and Runtime remains 98.58% (2,007/2,036).
