# Local speech synthesis (M4-06)

Verified on 2026-11-13. Core adds SpeechSynthesizer and AudioOutput; Testing adds
MockSpeechSynthesizer. AppleSpeechSynthesizer returns complete signed 16-bit PCM
WAV data, sample rate, channel count and sample-frame count. Hosts control storage
and playback.

## Native API evidence

The installed AVFAudio headers verify available voice enumeration, identifier
lookup, voice traits, AVSpeechSynthesizer.write(_:toBufferCallback:), immediate
stop and the cancellation delegate. Identifier lookup returns nil for voices
unavailable on the device. Buffer headers verify channel-data pointers and the
stride rules for interleaved and non-interleaved samples.

The adapter uses available com.apple voice identifiers and excludes personal
voices. Default selection matches the requested language exactly and orders
identifiers deterministically. Explicit identifiers bypass language selection.
There is no asset-installation request or playback call in the adapter.

Native synthesizers and utterances stay on the main actor. The native callback
copies samples synchronously into Sendable PCM chunks, so native buffer objects
do not cross an isolation boundary. Float32, Int16 and Int32 source samples are
converted to signed 16-bit interleaved PCM with finite-sample checks and clipping.

## Limits and lifetime

Defaults allow 2,000 Swift input characters, 16 MiB encoded WAV bytes, 60 seconds
of output and a thirty-second generation timeout after voice selection. Blank
text and invalid limits fail before rendering. Accepted output is mono or stereo
at an integer sample rate from 1 through 192,000 Hz.

An eight-chunk stream bounds the callback queue. Queue overflow, format changes,
invalid metadata and output byte/duration limits fail before returning a result.
Native voice-engine memory is outside these output bounds. The zero-frame native
callback ends normal output; no-audio completion is an error.

Timeout and task cancellation finish the stream, stop the owned synthesizer and
discard partial output. The deadline task is cancelled on every exit. Native work
already underway can take time to return. The cancellation delegate also reports
spontaneous native cancellation as a typed speech failure.

## Verification

Six portable adapter functions cover configuration forwarding, exact text/output
bounds, Unicode, WAV byte order and AVAudioFile decoding, changed formats,
malformed chunks, empty completion, output limits, channel order, finite-sample
checks, integer PCM conversion, typed failures and cancellation. Core and mock
tests cover the protocol, metadata, recorded requests and scripted errors.

Three opt-in native functions passed on macOS 26.6.2. An available Apple en-US
voice generated nonzero PCM audio for a short sentence; the emitted WAV decoded
to the reported frame count and sample rate. A short generation deadline stopped
a longer request with the expected timeout error, and an unknown voice failed
explicitly. The native test generated data without playback. Human listening,
pronunciation and phone resource use remain unmeasured.

The warning-free build, full default suite with 800 registered functions,
network-disabled suite, 24 demo functions, seven probe functions, all 71 Python
checks, strict formatting/layering, DocC and generic iOS build pass. Native tests
remain opt-in; existing iOS metadata/orientation warnings remain.

Core/Runtime coverage is 98.73% (2,959/2,997), down 0.13 percentage points from
M4-05's 98.86%. Core is 99.17% (953/961), down from 99.48%; Runtime is 98.53%
(2,006/2,036), down from 98.58%, with Runtime source unchanged.

M4-05 remains open because en-US recognition assets are absent on the development
Mac. TTS voice availability is independent of SpeechTranscriber asset availability.
Native transcription acceptance, active native cancellation checks, runtime audio
attachments and the complete voice workflow remain M4-05/07/09/12.
