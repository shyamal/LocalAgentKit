# Multimodal resource measurements (M4-10)

Verified on 2026-11-16, following merged M4-09 work in PR #80. M4-10 is in
progress: the portable probe, wired resource evidence and unplugged OCR/synthesis
observation are complete; native transcription resource measurements remain open.

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
must be evaluated. Native STT resource measurement still requires host-provisioned
speech assets; no installation was requested and that path remains unmeasured.
M4-10 stays in progress for native transcription coverage. The fixed-order synthetic
workload does not certify receipt accuracy, microphone capture, voice playback,
whole-agent energy or the battery cost of a user session.
