# Multimodal resource measurements (M4-10)

Verified on 2026-11-16, following merged M4-09 work in PR #80. M4-10 is in
progress: the portable probe, wired resource evidence and unplugged OCR/synthesis
observation are complete. A subsequent native transcription latency/memory/thermal
run is retained below; the completed longer native STT battery observation is retained in the final section.

## Implementation

A separate MultimodalProbe iPhone app uses the SDK's native OCR, transcription
and synthesis providers with synthetic fixtures. A portable, injectable runner
paces serial paths against monotonic time, includes an idle control, records
per-operation latency and process/device snapshots, and retains cancellation or
interruption as an incomplete JSONL run. Critical thermal state and foreground
loss stop further operations. No SDK source, defaults or runtime dependencies
changed. CI now tests the portable probe and its formatting.

The app samples battery/charging state, low-power mode, thermal state, foreground,
brightness and TASK_VM_INFO process footprint. UIKit sampling is main-actor
isolated; encoded image and synthesized speech preparation are outside measured
phases. The native APIs follow the existing verified OCR fixture, speech provider
and Phase-0 resource sampler; the new app compiles warning-free under Swift 6
strict concurrency, with the existing AppIntents metadata extraction warning.
No signing team is committed.

The host inspector validates fresh run identity, workload hash, event ordering,
phase completeness and finite observations. Battery results are excluded for
short, charging, unknown, interrupted or materially changed conditions. Failed
and unavailable paths cannot become zero-cost successes. It computes no energy,
per-hour battery extrapolation or baseline-subtracted provider effect.

## Physical exploratory run

The signed **Release** app ran on the paired **iPhone 15 Pro (iPhone16,1),
iOS 27.2 (24B115)**, connected by cable. Each available phase lasted at least
60 seconds with a 250 ms rest after every operation. The order was idle, OCR,
transcription, synthesis. A prior trial preceded the retained run, and preparation
warmed synthesis; this is not a cooled/cold-start or randomized comparison.

| Path | Successful calls | p50 ms | p95 ms | Maximum sampled footprint MiB | Thermal snapshots |
|---|---:|---:|---:|---:|---|
| Idle loop | 229 | 0.0012 | 0.0022 | 16.88 | fair: 231 |
| Accurate OCR | 144 | 156.69 | 161.68 | 73.22 | fair: 146 |
| Recorded-audio STT | unavailable | — | — | — | No measured phase |
| Speech synthesis | 141 | 153.88 | 156.81 | 43.28 | fair: 143 |

Every observed thermal snapshot was fair; no change was observed between calls.
These counts are not durations and can miss transitions during native work.
Idle latency measures an empty closure, not user-perceived responsiveness.
Footprint includes process/framework state at sampling time and is not a peak.

English recognition assets were **not installed on this iPhone**, so the STT
phase was explicitly skipped. The generated known recording was available; no
transcription success, latency or cost is inferred from that skipped path.

The device was charging throughout the sampled phases and its reported level
increased during idle. **All battery results are ineligible and contain null drain
values.** This run establishes no battery budget or energy improvement. The
separate 300-second-per-phase untethered protocol remains required.

Retained [raw observations, summary and manifest](../Benchmarks/MultimodalResources/results/iphone-wired-2026-11-16)
include source hashes, SDK commit, Release executable hash, toolchain, fixture
hashes and the fresh run UUID. Device name, serial, UDID and development-team
identity are excluded. The source and binary hashes were captured before launch;
only the fresh final run is reported. The host independently regenerated the
summary from raw JSONL with the expected UUID and pinned workload hash.

## Verification

- Five new portable Swift functions passed; injected time/work requires no native
  assets or device. They cover completion/order, unavailable/failing operations,
  late cancellation, background/critical interruption and invalid plans.
- Eight new report-inspector Python functions passed; all **79 Python tests** pass.
- SDK warning-free build, full default suite with **822 registered functions**, and
  full offline suite pass. No SDK source changed in this task.
- Core/Runtime coverage **98.98% (3312/3346)**, up 0.12 percentage points from
  M4-09. Core remains 99.59% (980/984); Runtime is 98.73% (2332/2362), up 0.17
  points with unchanged source and four more covered lines in this run.
- Existing demo: 26 registered functions; EmbeddingProbe: seven. Strict SDK/probe
  formatting, architectural layering and actionlint passed.
- DocC build/route validation passed (10,111 internal references).
- Signed physical iOS Release build, installation, launch, result retrieval and
  independent report validation succeeded. Only the existing AppIntents metadata
  warning was emitted for the probe build.

Logs are under `/tmp/lak-m410-`. The initial CLI environment argument was corrected
from a file path to the JSON string required by devicectl before retained launch.
No failed or superseded trial is presented as completed measurement evidence.

## Unplugged acceptance, 2026-11-16

The user unplugged the same installed Release app and manually started the battery
protocol. A new report, distinct from the wired run, completed with three available
300-second phases (about 15 minutes total; STT was unavailable). It was retrieved
only after the user reported completion and reconnected the phone.

| Path | Calls | Duration s | p95 ms | Maximum sampled footprint MiB | Battery change |
|---|---:|---:|---:|---:|---|
| Idle loop | 1,139 | 300.00 | 0.0017 | 21.24 | 0 percentage points observed |
| Accurate OCR | 711 | 300.33 | 161.50 | 69.35 | 0 percentage points observed |
| Speech synthesis | 695 | 300.25 | 158.01 | 45.60 | 0 percentage points observed |

All 2,551 snapshots were foreground, unplugged, low-power mode off and nominal
thermal state. Sampled brightness stayed approximately 0.65; batteryLevel stayed
approximately 0.80. These three phases pass the inspector's observational battery
eligibility rules. **No resolved battery-level decrease was observed. This does
not establish zero drain, zero energy, or compliance with a battery-consumption
budget.** The coarse battery API can hide consumption below its reported resolution.
The unplugged run began nominal, unlike the earlier fair wired run; it is not a
controlled estimate of a charging or cooling effect.

[Unplugged raw observations, summary and manifest](../Benchmarks/MultimodalResources/results/iphone-unplugged-2026-11-16)
retain the fresh manual-run UUID, verified artifact hashes and matching input
hashes. Source/executable provenance is inherited explicitly from the earlier
wired manifest: no rebuild or reinstall occurred between runs. Current measured
source hashes still match the recorded build manifest. No identifying device or
signing metadata was added.

## Outstanding acceptance

Repeat longer untethered runs after cooling before drawing comparative or energy
conclusions, and use higher-resolution energy tooling if a numerical energy budget
must be evaluated. The historical runs above did not exercise STT. The follow-up below adds native
transcription measurements after explicit preparation; its longer battery
observation remains outstanding. M4-10 stays in progress. The fixed-order synthetic
workload does not certify receipt accuracy, microphone capture, voice playback,
whole-agent energy or the battery cost of a user session.

## STT follow-up after M4-12

A fresh Release build at SDK commit `e8b9b4b` installed and launched on the
same iPhone. Despite the voice app's successful host setup, the probe's own
preflight reported `recognitionAssets: not-installed`. Run
`D69B0C6C-E300-4B72-9B80-0D2E67B92F0F` therefore cannot close native STT
measurement acceptance and is not retained as new resource evidence.

The probe now offers explicitly confirmed English speech-data preparation using
`AssetInventory.assetInstallationRequest` and `downloadAndInstall`, verified
against the installed iOS SDK. This host action may use the network; measurement
and SDK recognition still never request installation. Cancellation cancels the
request's progress and checks task cancellation before reporting readiness;
system work may finish separately. Preparation is outside measured phases and
requires a fresh run afterward. Neither another app's readiness nor successful
setup alone counts as a measured transcription phase.

The updated signed Release build and strict formatting pass; five portable runner
and eight inspector functions pass. Only the existing AppIntents metadata warning
was emitted. SDK source is unchanged. At that point physical setup and new measurements remained pending. The next
section records the subsequently completed short run; no new battery result is claimed.

## Native STT resource run, 2026-11-16

After the user confirmed the probe's explicit speech preparation was ready,
a fresh Release run `AAC3BAB3-500D-4CE7-B383-86E3DA6923B2` completed all four
60-second phases on the same iPhone. The header reports installed speech assets;
transcription used the SDK recognizer with the generated synthetic recording.

| Path | Calls | p50 ms | p95 ms | Maximum sampled footprint MiB |
|---|---:|---:|---:|---:|
| Idle | 229 | 0.0010 | 0.0013 | 17.22 |
| OCR | 143 | 154.86 | 160.02 | 76.06 |
| Recorded-audio STT | 139 | 164.05 | 167.67 | 44.88 |
| Synthesis | 140 | 153.82 | 156.07 | 22.88 |

All 659 snapshots were nominal, foreground, low-power mode off and reported
unplugged. Sampled brightness was approximately 0.65. The developer-controlled
launch does not establish the physical connection type; observed charging state
is taken from the report. Every phase is battery-ineligible because it is shorter
than 300 seconds. No battery drain or energy-budget result is claimed.

[Raw report, validated summary and build manifest](../Benchmarks/MultimodalResources/results/iphone-stt-2026-11-16)
retain fresh identity, source/executable/workload hashes and the explicit local
probe modification relative to the SDK commit. Independent host validation
confirmed completion and all phase boundaries. No microphone or user recording
was accessed. The known recording is generated during preparation; nonempty
transcription is the admission check, not a transcript-accuracy score. Sampled
process footprint is not peak usage. Fixed order, caching and preparation prevent
causal comparison with earlier runs. M4-10 remains partial for the longer native
STT battery observation; M4-09 active native cancellation is also still open.

## Battery follow-up inspected 2026-11-17

The user reported finishing the longer protocol. The retrieved synthetic report
started at `2026-11-16T09:11:18Z`, but its terminal record is **cancelled** at
758.95 seconds. Idle and OCR completed their 300-second phases; transcription
was interrupted and synthesis never started. The record does not establish why
cancellation occurred. Inspection with `--allow-incomplete` excludes every phase
from battery eligibility; no drain result or completion is inferred from the UI
report. M4-10 remains partial.

This attempt exposed a host bug: a manually started run reused the CLI environment
UUID and replaced the device's short-run report. The short report had already been
archived unchanged. The [cancelled raw report and conservative summary](../Benchmarks/MultimodalResources/results/iphone-stt-battery-cancelled-2026-11-16)
are retained separately, with inherited build provenance. Their shared UUID is
explicitly not evidence of freshness; startedAt, duration and artifact hashes
distinguish the two attempts.

Manual starts now always generate a fresh UUID; the CLI override applies only to
the automatic launch. Report creation uses atomic without-overwriting writes,
so repeated CLI UUIDs fail rather than truncate evidence. The Foundation-only
log moved to the portable target, with a regression checking an existing report
remains byte-for-byte intact. A fresh physical battery run is still required.

## Completed native STT battery protocol, 2026-11-17

The user started the corrected Release probe unplugged and reported the Finished
screen. Fresh manual UUID `9E1B70C7-EA85-424E-A772-D504859C2CDC` identifies a
complete run starting `2026-11-17T05:12:49Z`. The strict inspector, without
`--allow-incomplete`, validated all four phases and marked each battery-eligible.

| Path | Calls | Duration s | p95 ms | Maximum sampled footprint MiB | Observed battery decrease |
|---|---:|---:|---:|---:|---|
| Idle | 1,143 | 300.26 | 0.0011 | 16.72 | 0 percentage points |
| OCR | 708 | 300.16 | 160.98 | 74.27 | about 5 percentage points |
| Recorded-audio STT | 695 | 300.06 | 169.11 | 44.63 | 0 percentage points |
| Synthesis | 696 | 300.29 | 157.06 | 32.22 | about 5 percentage points |

All 3,250 snapshots were nominal, foreground, unplugged and low-power mode off,
with brightness approximately 0.70. Total observed battery decrease was about
10 percentage points. These coarse whole-device readings do not attribute drain
to providers, resolve sub-step consumption, or establish any energy-budget pass.
In particular, STT's zero resolved decrease does not mean zero energy. Fixed order,
warmed preparation, system activity and battery reporting resolution limit any
comparison between phases or earlier runs. Footprint is sampled process usage,
not a peak or provider-only allocation. No hourly extrapolation is made.

[Raw observations, strict summary and build provenance](../Benchmarks/MultimodalResources/results/iphone-stt-unplugged-2026-11-17)
are retained separately from both prior attempts. Source and executable hashes
were captured before this run and source hashes rechecked on retrieval. Device
identifiers and signing identity are excluded. Only synthetic reports were read;
no microphone, user audio or personal data was collected. Six portable runner/log
functions, eight inspector functions, strict formatting and the signed Release
build pass (only the existing AppIntents metadata warning). M4-10 measurement
coverage is complete; active native analyzer cancellation remains M4-09.
