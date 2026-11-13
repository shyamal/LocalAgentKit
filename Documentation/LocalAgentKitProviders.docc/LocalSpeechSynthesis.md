# Generate speech audio

Create WAV audio from text through the Core SpeechSynthesizer seam.

## Synthesize text

```swift
import LocalAgentKitCore
import LocalAgentKitProviders

func speechAudio(_ text: String) async throws -> AudioOutput {
    let synthesizer: any SpeechSynthesizer = try AppleSpeechSynthesizer(
        localeIdentifier: "en-US", maximumDuration: 60)
    return try await synthesizer.synthesize(text: text)
}
```

AudioOutput contains signed 16-bit interleaved PCM WAV bytes, sample rate,
channel count and sample-frame count. The host controls storage and playback.
These bytes can also be supplied to AudioInput for recorded-audio processing.

The default selection uses an available Apple voice with an exact
language match, ordered by identifier for deterministic selection. An explicit
voiceIdentifier selects that voice directly. Personal and third-party voice
identifiers are excluded. Missing voices produce a typed speech error; the
adapter makes no asset-installation request.

## Bound generation

Defaults allow 2,000 Swift text characters, 16 MiB of WAV output and 60 audio
seconds. Blank text fails before rendering. The native callback copies supported
Float32, Int16 or Int32 samples into signed 16-bit PCM, preserving channel order.
Supported output is mono or stereo at an integer rate through 192 kHz.

A bounded eight-chunk queue connects the native callback and result collector.
Queue overflow, changed formats, invalid samples and exceeded output limits fail
generation. Output limits do not cap the native voice engine's working memory.

The default generation timeout is thirty seconds, starting after voice selection.
Timeout and cancellation stop the request and discard partial output. Native work
already underway can take time to return. A normal request returns complete WAV
audio after the native end-of-audio callback.

## Test a host

MockSpeechSynthesizer records requested text and returns host-supplied AudioOutput
values or typed errors. It generates no native audio.

```swift
import LocalAgentKitTesting

let synthesizer = MockSpeechSynthesizer { _ in fixtureAudio }
```

The native verification generated nonzero audio and decoded its WAV frame count
and sample rate on macOS. It also exercised the generation timeout. Human listening,
pronunciation quality and phone resource measurements remain separate checks.
