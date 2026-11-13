# Transcribe recorded audio

Use the Core SpeechRecognizer seam with locally installed SpeechTranscriber assets.

## Supply encoded audio

The host supplies authorized recorded audio bytes.

```swift
import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders

func transcript(_ data: Data) async throws -> String {
    let recognizer: any SpeechRecognizer = try AppleSpeechRecognizer(
        localeIdentifier: "en-US", maximumDuration: 60)
    return try await recognizer.transcribe(audio: AudioInput(data: data))
}
```

The adapter checks encoded size and decoded frame duration, then uses
SpeechAnalyzer and SpeechTranscriber for the selected locale. It checks that the
language assets are installed before starting analysis. The host provisions those
assets explicitly through OS asset management.

Defaults accept 16 MiB of encoded data, 60 seconds of decoded audio and 20,000
Swift transcript characters. WAV decoding is covered by generated fixtures;
other formats depend on the platform audio decoder. The input bounds are admission
limits and do not cap native model memory.

## Understand lifetime and results

Encoded data is written into a unique owner-only temporary directory for the
file-based analyzer. Cleanup is attempted on success, failure and cancellation.
The host owns original recordings, capture authorization and retention.

The analyzer feeds the file and consumes recognition results concurrently. Only
final result text is appended, retaining the native fragments' formatting.
Oversized output fails as a typed speech error. Empty recognition returns an
empty string.

If feeding or result collection fails, the session requests analyzer cancellation
before waiting for both sides to end. Task cancellation also requests native
cancellation and discards late output. Native work already underway can take time
to return.

The adapter declares local processing. Hosts invoking alternative recognizers
must honor their network declarations. Microphone capture, runtime audio
attachments and the voice UI follow in later Milestone 4 tasks.

## Test without installed models

MockSpeechRecognizer in LocalAgentKitTesting records AudioInput values and supplies
scripted text or typed failures.

```swift
import LocalAgentKitTesting

let recognizer = MockSpeechRecognizer { _ in "Scripted transcript" }
```

The native checks report asset state explicitly. On the verified development Mac,
the en-US assets were absent and the provider returned the expected typed failure.
Successful native speech transcription still needs validation with installed
assets and a known spoken recording.
