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

This first adapter supplies image categories. OCR, object locations, structured
document extraction and image attachments to the runtime are subsequent
Milestone 4 tasks.
