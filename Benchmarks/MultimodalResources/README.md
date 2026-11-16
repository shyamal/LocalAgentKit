# Vision and speech resource measurements (M4-10)

Use the separate [MultimodalProbe](../../Examples/MultimodalProbe/README.md) app.
This is a pinned exploratory measurement protocol, independent of SDK defaults,
LocalAgentDemo and any personal data. Wired and unplugged OCR/synthesis observations are retained. Native STT
resource acceptance remains pending recognition assets.

## Protocol fixed before retained collection

- Fixed serial order: idle, accurate English OCR, recorded-audio transcription,
  speech synthesis. Default phases last 60 seconds; the battery protocol uses
  300 seconds each. An unavailable path is skipped with its reason, not measured
  as zero work. A failed path is explicitly marked failed even if later phases run.
- Each operation is followed by a 250 ms rest. This is a maximum of four calls
  per second, not a constant call rate. Idle uses the same loop, sampling, UI and
  logging with an empty operation. Operation latency excludes the following rest,
  snapshot and log write; phase duration includes their overhead. A slow operation
  can overshoot a phase; this harness does not forcibly interrupt native work at
  a phase boundary. The synthesis provider has a 15-second call timeout.
- Fixed 800 × 300 image, Helvetica 40, black `INVOICE 42` at (40, 150) on white.
  OCR must contain that line. The selected installed Apple en-US voice synthesizes
  the pinned phrase once during preparation to create the STT recording. STT must
  return nonempty text; this check is not transcription quality evaluation.
- Image generation, initial synthesis, provider setup and asset-state checks are
  outside phase timing. Synthesis is warmed; first OCR/STT calls remain measured.
  Providers stay alive across the same-process run, so memory includes retained
  framework caches and previous phases. Input hashes and voice/asset state are
  captured, since different OS/voice assets need not generate identical audio.
- The app remains foreground with idle timer disabled. Brightness is not changed
  by the probe. Thermal state, battery level/state, low-power mode, brightness and
  process physical footprint are sampled between calls. Slow calls create sampling
  gaps. Foreground loss, cancellation and critical thermal state stop the run;
  partial JSONL remains available but is not a completed measurement.
- `task_info(TASK_VM_INFO).phys_footprint` is sampled whole-process footprint,
  not instantaneous live heap, device RAM, GPU allocation, or a high-water peak.
  The implementation follows the installed SDK API already used in Phase 0.
  UIKit battery/foreground/brightness access stays in the app on the main actor.
- No camera/microphone access, playback or asset installation is requested. OS
  asset services remain OS-owned; absence of an app networking API is not a
  traffic-capture certification.

## Interpretation and battery eligibility

The host inspector checks schema/version, contiguous sequence, monotonic finite
elapsed time, exact phase order, fresh run ID and pinned workload hash. It rejects
incomplete declared completion, malformed samples, stale/corrupt logs and data
after a terminal event. Interrupted/partial inspection requires an explicit flag.

Each battery result requires a completed phase and run, at least 300 seconds of
observed phase duration, all sampled battery levels known and unplugged, no
observed level increase, stable low-power mode, foreground state and sampled
brightness within 0.01, and no unknown/critical thermal state. An unavailable or
failed path cannot qualify. Invalid battery results contain no drain value.

Eligibility is based on observations with gaps, not continuous power telemetry.
A zero percentage-point change can be below the battery API's resolution; it is
not proof of zero energy. No joules, watts, baseline-subtracted cost, per-hour
extrapolation or causal provider energy comparison is inferred. Fixed phase
order, thermal carryover, warmed caches and unrelated system activity confound
comparisons. Repeat untethered runs after cooling, with the same brightness,
low-power mode, OS and assets before drawing broader conclusions. The idle phase
is retained as context, not subtracted from the other phases.

Nearest-rank p95 and median latency are computed over successful operation samples.
Thermal counts count snapshots, not time spent in each state. Footprint summaries
are maximum **sampled** values and can miss a transient peak. Raw per-operation
observations are retained so those limitations remain inspectable.

## Provenance

Retained results include raw JSONL, independently generated summary, workload hash,
source hashes, SDK commit, Release executable hash and toolchain/device model/OS.
Device name, UDID, serial, development-team identity and provisioning data are
excluded from committed artifacts. A preliminary launch used incorrect CLI JSON
argument syntax and collected no run; a subsequent trial was superseded after
preparation/build-mode metadata wording was finalized. Only the fresh final run
is used for reported measurements.

## Current acceptance

Wired physical resource acceptance and portable checks are recorded in
[`docs/multimodal-resources-verification.md`](../../docs/multimodal-resources-verification.md).
Unplugged idle/OCR/synthesis phases pass observational battery eligibility;
native STT remains unavailable. M4-10 remains in progress for transcription
resource coverage. No energy budget is inferred from the coarse battery readings.

Retained wired results: [iPhone 15 Pro / 2026-11-16](results/iphone-wired-2026-11-16/summary.json).
OCR completed 144 calls (p95 161.68 ms, maximum sampled footprint 73.22 MiB);
synthesis completed 141 calls (p95 156.81 ms, 43.28 MiB). Every sampled thermal
state was fair. STT was unavailable because recognition assets were absent.
All battery values are excluded because the phone was charging and phases were
shorter than the battery protocol. These are uncontrolled exploratory observations.

Retained [unplugged results](results/iphone-unplugged-2026-11-16/summary.json)
contain three available five-minute phases: idle 1,139 calls, OCR 711 and synthesis
695. Every snapshot was nominal, foreground and unplugged with stable brightness
and low-power mode. Battery level did not change at the API's reported resolution;
that is not zero energy or a battery-budget pass. OCR p95 was 161.50 ms and synthesis
158.01 ms. STT remained unavailable, shortening the four-phase protocol to about
15 minutes. See the verification notes for sample counts and build provenance.
