# Built-in object detection (M4-03)

Verified on 2026-11-13. AppleVisionProvider adds a configured object-detection
initializer for people, cats and dogs. Classification remains available through
the default initializer, and OCR through its text-recognition initializer.

## Supported native operations

The installed macOS 27.2 Vision swiftinterface verifies
DetectHumanRectanglesRequest revision2, its upperBodyOnly setting and
HumanObservation confidence/boundingBox. It also verifies RecognizeAnimalsRequest
revision2 and RecognizedObjectObservation labels, confidence and boundingBox.
These requests are available from macOS 15 and iOS 18.

The provider runs full-body people detection and/or cat/dog recognition, according
to a nonempty set of configured targets. Revision 2 is explicit for compatibility
with the package's 26.4 floor. Combined requests run people first, then animals.
Each request uses the admitted bytes and resolved EXIF/host orientation, with
cancellation checks before and after each native await.

Core gains VisionObjectObservation and an empty-by-default
VisionResult.detectedObjects field. Each object contains category predictions,
native detection confidence and a normalized lower-left bounding box in the
oriented image. People receive the SDK label person. Animal identifiers and
label confidences are retained from native observations. Detection confidence
and label confidence have separate meanings and remain separate values.

The existing mock can return these observations through its original handler.
Framework imports stay in Providers, with no new protocol or third-party dependency.

## Validation and selection

The existing 16 MiB encoded-byte and 24-million-pixel defaults apply before
detection. Returned observations must have finite confidence in zero through one,
a positive finite region within the normalized image, and nonempty valid labels.
Malformed output fails before filtering, including malformed low-confidence
objects. OCR and detection share the same normalized-region validator.

The minimum confidence is inclusive and defaults to zero. It applies to detection
confidence. Results are sorted by descending confidence, preserving native source
order for ties, then limited to twenty by default. These controls select returned
results after native work. They do not limit native memory or computation, and
their defaults are not application-specific calibrated operating points.

Cancellation discards late results. Native work already running may take time
to return. Native failures map to AgentError.visionFailure; cancellation maps to
AgentError.cancelled. Empty detection and fully filtered output are valid results.

## Evidence and remaining validation

Seven portable adapter functions cover target/orientation forwarding, label and
region preservation, inclusive filtering and stable ranking, empty output, invalid
settings, malformed observations, image admission, error mapping and cancellation.
Additional Core and mock functions verify separate confidence fields and use
through the existing protocol.

The native opt-in function passed all three cases on macOS 26.6.2: people,
animals, and their combination on a generated blank PNG. It checks native request
execution and empty-result handling. Positive object examples in the portable
tests are scripted. Positive-photo detection, localization accuracy and false
positive/negative rates remain unmeasured. There is no custom-model or arbitrary
category detector in this built-in mode.

Warning-free SDK build, the full default suite with 763 registered functions,
the network-disabled suite, 24 demo functions, seven probe functions, 70 Python
tests, strict formatting/layering, DocC and the generic iOS build pass. Native
tests remain opt-in. Existing iOS AppIntents metadata and orientation warnings
remain.

Core/Runtime coverage is 98.82% (2,928/2,963), down 0.03 percentage points from
M4-02. Core is 99.46% (922/927). Runtime covered one fewer line at 98.53%
(2,006/2,036), with its source unchanged. This task's native checks ran on the
Mac; phone resource use and end-to-end image attachments remain later work.
