# Analyze local image data

Classify an encoded image through the Core VisionProvider seam.

## Supply encoded bytes

The host obtains authorized image data, then passes it to the provider.

```swift
import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders

func imageCategories(_ data: Data) async throws -> VisionResult {
    let provider: any VisionProvider = try AppleVisionProvider(resultLimit: 5)
    return try await provider.analyze(image: ImageInput(data: data))
}
```

The AppleVisionProvider uses the native Vision classifier locally and returns
category identifiers with confidence values. The default limits are 16 MiB of
encoded bytes, 24 million pixels in the first image, and five categories. A
container with several images is analyzed from its first image.

Encoded orientation metadata applies by default. Supply an explicit orientation
when the host knows the bytes need a different interpretation.

```swift
let input = ImageInput(data: data, orientation: .right)
```

The limits bound accepted input sizes. Native decoding and inference can use
additional memory. Classification confidence is supplied by Vision and can vary
with its revision and operating-system assets.

## Recognize text

Use the text-recognition initializer for OCR. Recognition returns text regions
with confidence and bounding boxes.

```swift
let options = try AppleVisionProvider.TextRecognitionConfiguration(
    languages: ["en-US"], automaticallyDetectsLanguage: false)
let provider: any VisionProvider = try AppleVisionProvider(textRecognition: options)
let result = try await provider.analyze(image: ImageInput(data: data))
let text = result.text
let regions = result.recognizedText
```

The default OCR level is accurate. Fast recognition, automatic language detection
and language correction are configurable. Empty language hints retain the native
defaults; explicit hints must be supported by the selected native recognizer.
Unsupported hints fail with a typed vision error.

Bounding boxes use normalized coordinates with the origin at the lower-left of
the oriented image. Region order is supplied by Vision. The joined text preserves
that order with newlines; complex documents may need later layout analysis.

OCR defaults to at most 200 returned regions and 20,000 Swift characters, counting
the inserted newlines. Exceeding either limit fails the entire operation. Empty
recognition is a successful empty result. These output bounds are checked after
native recognition and do not limit its internal working memory.

## Locate people and animals

The built-in detection mode locates people, cats and dogs. Choose the detector
families explicitly to control which native requests run.

```swift
let options = try AppleVisionProvider.ObjectDetectionConfiguration(
    targets: [.people, .animals], minimumConfidence: 0.5, resultLimit: 20)
let provider: any VisionProvider = try AppleVisionProvider(objectDetection: options)
let result = try await provider.analyze(image: ImageInput(data: data))
let objects = result.detectedObjects
```

Each object retains labels, native observation confidence and a normalized
bounding box in the oriented image. People use the SDK label `person`; animal
label identifiers are passed through from Vision. Observation confidence and
label confidence are separate values. The cutoff filters observation confidence;
its value in this example is illustrative.

The default cutoff is zero and the default result limit is twenty. Results are
ranked by descending observation confidence, preserving source order for ties.
The combined mode runs people first, then animals. Limits select the top results
after native detection; they do not bound native computation or memory.

Revision 2 of each built-in request preserves the SDK's deployment floor.
Positive-photo accuracy and application-specific confidence cutoffs need separate
validation. Runtime image attachments and structured document extraction remain
subsequent tasks.

## Handle failures and cancellation

Malformed images, oversized inputs and native processing failures throw
`AgentError.visionFailure`. A cancelled task throws `AgentError.cancelled`.
The provider checks before processing and after awaiting native inference, so
a result that arrives after cancellation is discarded. Native work already in
progress may take time to return.

Image input contains bytes and orientation. The host owns file selection, camera
or photo permissions, any file-provider downloads and network policy for other
implementations. The Apple adapter declares `requiresNetwork == false`.

## Test with a mock

MockVisionProvider in LocalAgentKitTesting records its input and returns a
host-supplied result or failure without native assets.

```swift
import LocalAgentKitTesting

let mock = MockVisionProvider { _ in
    VisionResult(classifications: [
        VisionClassification(identifier: "document", confidence: 0.9)
    ])
}
```

Use the default initializer for image categories, the text-recognition initializer
for OCR, or the object-detection initializer for located people, cats and dogs.
Structured document extraction and runtime image attachments follow in Milestone 4.
