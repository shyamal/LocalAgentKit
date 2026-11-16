# Multimodal cancellation acceptance (M4-09)

Verified on 2026-11-16, following merged M4-08 / PR #79. This adds runtime
acceptance and active native synthesis cancellation. M4-09 remains in progress:
successful native transcription and its cancellation need recognition assets.

## Runtime cancellation and stale approval fix

New parameterized acceptance runs both an active VisionProvider and an active
SpeechRecognizer through AgentRuntime.cancelCurrentRun. Cooperative providers
observe cancellation; the run returns typed cancelled, publishes one cancelled
error and no completion, performs no tool/model work, records no history, and
publishes no successful attachment progress. Existing M4-07 tests continue to
cover abandonment and late-result rejection for an uncooperative provider.

A second regression cancels a run while its attachment-derived write is awaiting
approval, then starts a fresh run with the same workflow. It exposed a real bug:
planner call IDs restarted at `write#1`, allowing an old approval to resolve the
fresh run's wait. The reproduction failed before the fix; the fresh approval was
incorrectly accepted under the old ID.

AgentRuntime now assigns a UUID-prefixed execution ID to every planner invocation.
The same execution ID flows through permission requests, tool events, results and
planner observations, including a repaired call. A later planner invocation gets
a new ID even when the planner returns an identical local ID. Loop detection still
uses tool/argument signatures, independently of IDs. Hosts must treat runtime
call IDs as opaque and use the current permission event's ID.

The regression now rejects the old approval while the new request is pending.
No write or history record exists for the cancelled run; the fresh run requires
its own approval before its one write. This also prevents delayed cancellation
handlers keyed by the old call ID from targeting the fresh permission request.

## Recording cleanup

An externally cancelled AppleSpeechRecognizer call is suspended after real WAV
decoding and private temporary-file creation. Cancelling its task produces typed
cancelled and removes the entire private recording directory before return. The
recognition runner is injected; this is lifecycle/cleanup acceptance, not a claim
that native SpeechAnalyzer successfully transcribed audio without its assets.

## Active native speech synthesis

The installed AVFAudio header confirms buffer-writing and stopSpeaking APIs.
An internal optional buffer observer synchronizes the native acceptance test at
a real nonempty copied PCM buffer. It does not change the public synthesis API.
The test cancels the synthesis task directly from that callback, with a Mutex
protecting the task handle and callback-before-attachment race. There is no timed
sleep used to guess whether native synthesis has started.

The cancelled task returns AgentError.cancelled without partial AudioOutput;
render's cancellation/defer paths finish the stream and stop the owned native
synthesizer. A subsequent independent request produces nonempty audio. This
native check passed on the Mac alongside normal synthesis, timeout and unknown-
voice acceptance. The test retains no user audio and does not play its output.

Run the native acceptance with:

```bash
LOCALAGENTKIT_DEVICE_TESTS=1 swift test --filter 'AppleSpeechSynthesisNativeTests|AppleSpeechNativeTests'
```

All six selected functions passed. The native recognition preflight still reports
`en-US assets absent; no installation requested`. Negative-path success is not
successful-transcription or active-native-STT-cancellation acceptance.

## Verification

- Warning-free Swift build; full default suite with 822 registered functions.
- Full offline suite passed without disabling tests.
- Core/Runtime coverage: 98.86% (3308/3346), down 0.03 percentage points from
  M4-08. Core is 99.59% (980/984), up 0.30 points; Runtime is 98.56%
  (2328/2362), down 0.17 points with three additional executable lines and one
  fewer covered line.
- Demo package: 26 registered functions. EmbeddingProbe: seven. Python: 71.
- Strict formatting, layering and DocC route checks passed (10,111 internal
  topic references). Generic iOS demo build passed with existing AppIntents
  metadata and interface-orientation warnings; library compilation is warning-free.

Logs use `/tmp/lak-m409-`: `build`, `focused`, `coverage`, `offline`, `native`,
`demo`, `probe`, `python`, `format`, `layering`, `docs` and `ios`. The pre-fix stale
approval reproduction is `/tmp/lak-m409-stale-reproduction.log`.

## Remaining acceptance

M4-05/09 still need installed recognition assets and a known spoken recording for
successful native STT, cancellation during that native session and cleanup on the
actual native path. No download or asset-installation request was made. Physical
camera/vision cancellation, phone resource behavior and complete voice playback
acceptance remain device checks. The tests above establish runtime propagation,
late-result isolation, approval invalidation, recording cleanup and active native
TTS cancellation on the development Mac; they do not claim immediate termination
of every native framework operation.
