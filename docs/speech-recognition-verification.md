# Recorded-audio recognition (M4-05, native acceptance pending)

Implemented on 2026-11-13. Core adds AudioInput and SpeechRecognizer; Testing adds
MockSpeechRecognizer. Providers adds AppleSpeechRecognizer for recorded bytes
using SpeechAnalyzer and SpeechTranscriber. The host supplies authorized audio
and provisions installed language assets.

## Verified SDK and behavior

The installed macOS 27.2 Speech swiftinterface verifies locale support resolution,
SpeechTranscriber availability and results, AssetInventory status, SpeechAnalyzer
start(inputAudioFile:finishAfterFile:) and cancelAndFinishNow. These APIs are
available from OS 26, below the package's 26.4 floor. AVAudioFile headers and
compilation verify recorded-file decoding, frame count and processing format.

Defaults accept 16 MiB of encoded data, 60 seconds as reported by the decoder's
frame count/sample rate, and 20,000 Swift transcript characters. Empty, unreadable,
over-byte and over-duration inputs fail before recognition. Output exceeding its
character budget fails without returning a partial transcript. Empty recognition
is valid.

The adapter writes a unique owner-only temporary directory and attempts removal
on every exit path. Generated WAV fixtures verify exact bytes and decoding,
permission mode 0700, and cleanup on success, error and cancellation. Input limits
do not bound native working memory, and cleanup does not define crash recovery.

Only final native text fragments are concatenated. The session concurrently feeds
the audio file and consumes results, allowing an error on either side to request
native cancellation before waiting for both sides to finish. External cancellation
also requests native cancellation and late output is discarded. Native work may
take time to return.

The recognizer checks locale support and installed module status before analysis.
It has no asset-installation call, microphone capture or playback. Host calls are
separate from runtime audio attachments, network configuration and voice UI work.

## Checks completed

Two Core and two mock functions verify values, typed speechFailure messages, the
protocol contract, network declarations, scripted output and cancellation.
Eight portable provider functions cover real encoded WAV decoding, exact input
bounds, invalid configuration, Unicode/empty output, errors, private-file cleanup,
session completion, either-side failure and cancellation releasing a waiting side.
The session tests use deterministic actor latches and load no native model.

Both opt-in native functions passed on macOS 26.6.2. The requested en-US locale was
supported but its SpeechTranscriber assets were not installed. The provider
returned the expected typed missing-asset failure, and an unsupported locale
returned its typed unavailable-locale failure. No installation was requested.
The native test log explicitly distinguishes this outcome from installed-model
silence analysis.

The warning-free build, full default suite with 788 registered functions,
network-disabled suite, 24 demo functions, seven probe functions, 71 Python tests,
strict formatting/layering, DocC and generic iOS build pass. The layering guard
now rejects AVFoundation and AVFAudio in Core/Runtime, with a regression covering
both imports in both targets. Existing iOS metadata/orientation warnings remain.

Core/Runtime coverage is 98.86% (2,956/2,990), down 0.07 percentage points from
M4-04. Core rises to 99.48% (949/954); Runtime is 98.58% (2,007/2,036), covering
two fewer lines with its source unchanged.

## Acceptance remaining

M4-05 stays in progress. Provision the requested native assets through a host
application, then exercise successful native transcription with an authorized
known spoken recording and compare the result. Verify cancellation and temporary
cleanup on that native success path as well. The current native result verifies
availability handling; the feed/result bridge is covered by injected lifecycle
tests.

The native command is LOCALAGENTKIT_DEVICE_TESTS=1 swift test --filter
AppleSpeechNativeTests. Inspect its asset-state log when assessing the outcome.
Speech accuracy, phone resource use and microphone/voice integration need their
own evidence. M4-06 text-to-speech and M4-12 voice workflow remain separate tasks.
