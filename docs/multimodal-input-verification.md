# Multimodal runtime input (M4-07)

Verified on 2026-11-13. AgentRuntime accepts AgentInput with text and any
combination of encoded images, recordings and already-extracted documents.
The existing String entry point forwards to the same implementation.

## Behavior and bounds

AgentConfiguration optionally supplies VisionProvider and SpeechRecognizer.
Construction rejects invalid input limits and network-requiring input providers
under `.never`. Preflight checks every attachment before invoking a provider:
count, aggregate source bytes, empty image/audio and required provider presence.
Defaults are four attachments, 16 MiB source bytes and 64 KiB normalized excerpt
bytes including labels. Document source size includes title and text UTF-8.

Preprocessing is sequential under the existing run deadline. It samples thermal
pressure between attachments and passes cancellation to providers. The deadline
helper abandons uncooperative work: it can retain data until it returns, but a
late result cannot publish progress or enter another run. Providers enforce their
own native limits; source/output limits do not bound native framework working
memory.

Vision output preserves categories, recognized text, object labels/locations and
document transcripts/title/table dimensions/cell spans. Audio becomes a transcript.
Documents retain their title and text. Each body is split into 512-character
excerpts with fixed untrusted-source labels. Excerpts are interleaved across
attachments and precede automatic RAG/memory passages in ContextBudgeter.
Whole excerpts may be dropped to fit a model request. Processing progress counts
normalized attachments, not retained excerpts or model comprehension.

There is no implicit ingestion or separate raw/extracted-content conversation
recording. Completed goals and answers are remembered, including source content
quoted in answers. Model providers receive the excerpts retained by budgeting.
Source labels are guidance; permission enforcement still occurs in ToolExecutor.

The runtime now reserves its active task before reading conversation history and
through completed-turn recording, preventing overlapping runs across those awaits.

## Portable acceptance

Eleven focused runtime tests cover combined input, binary exclusion from prompts,
conversation retention, explicit history override, legacy String runs, progress,
all-input preflight, limits, offline provider declarations, extracted-output bounds,
typed provider failure, cancellation, late results, concurrent-run rejection,
run deadlines, interleaving/budget trimming, structured image rendering, changed
thermal pressure, malicious source instructions and the tool approval gate.
One regression keeps a second run out while history summarization records
the completed first run.

The recording regression initially used only one turn and therefore never reached
summarization. That new fixture was corrected to seed an earlier turn. The stale
focused/offline processes were stopped and final checks used the rebuilt fixture.

## Scope still pending

This acceptance uses existing scripted Vision/Speech providers; it does not claim
successful native speech transcription or device multimodal quality. Native STT
acceptance still needs installed assets and a known recording (M4-05). Camera
capture, file authorization/extraction, microphone capture and playback remain
host responsibilities. The receipt and voice demos and native cancellation/
resource acceptance remain M4-08..12.

## Verification results

- Warning-free Swift build under strict concurrency.
- Full default suite: 811 registered test functions, including gated native tests.
- Core coverage 99.59% (977/981); Runtime 98.64% (2179/2209).
  Combined 98.93% (3156/3190), up 0.20 percentage points from M4-06.
  Core increased 0.42 points and Runtime increased 0.11 points.
- Offline suite passed on unchanged retry. The first final offline run's Providers
  helper exited with signal 11. Its crash report starts at NSDictionary mutation
  in Core Data's `_generateTriggerSQL`; no causal link to this change is established.
  Preserved log: `/tmp/lak-m407-offline-final.log`; successful retry:
  `/tmp/lak-m407-offline-retry.log`. No tests were disabled.
- Demo package: 24 tests; EmbeddingProbe: seven tests; Python checks: 71.
- Strict formatting and architectural layering checks passed.
- DocC build and static-route validation passed with 10,072 internal references.
- Generic iOS demo build passed. Existing AppIntents metadata and interface
  orientation warnings remain; library compilation is warning-free.

Final coverage log: `/tmp/lak-m407-coverage-final.log`. Focused tests:
`/tmp/lak-m407-focused-final.log`. Example, docs and iOS logs use the
`/tmp/lak-m407-` prefix. No native/device multimodal run was claimed for this task.
