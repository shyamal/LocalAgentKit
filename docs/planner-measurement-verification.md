# Current planner measurement (M5-03)

Paired Mac and iPhone evidence collected 2026-11-21. M5-03 is **complete with a
no-go promotion decision**: keep the state-machine default. The current fixture
results do not support promoting ModelDrivenPlanner. Neither fixture results nor schema validity establish
real built-in-tool success.

## Harness changes

MultiStepRunner accepts an explicit PlannerChoice, defaulting to stateMachine.
CLI `--planner state-machine|model-driven` applies to multi-step only. Reports
identify stateMachine-open or modelDriven-bounded-v1; offline M5 replay retains
that identity and selects the correct assessment scope. Unknown identities remain
rejected. The generic drift comparator rejects cross-planner comparisons.
Existing callers, default planner and suite data are unchanged.

Two new functions verify shared fixture/scoring behavior and model-driven scope
through assessment/replay. A third independently recomputes both OS assessments
and every single-tool validity score/summary from retained raw rows. The comparator's existing test now rejects mixed
planner identities. The synthetic integration plan explicitly uses empty-result
skip because the unchanged fixture write acknowledgement can be No results found;
a matching write call alone cannot guarantee a final answer under model-driven
empty-result handling. Live goals/fixtures were not tuned in response to results.

## Mac protocol and results

Hardware: Mac17,6, Apple M5 Max. OS: macOS 27.2.1 (26B131). Xcode 27.2 (27B52),
Debug build, FoundationModelProvider(maxDecodingRetries: 0), fixed UTC reference
from the bundled suites. Order: one model-driven smoke, model-driven 30 trials,
state-machine 30 trials, then single-tool 100 probes. Multi-step uses ten goals,
three repetitions and sixty-second deadlines. Single-tool uses twenty goals,
five repetitions and sixty-second deadlines. Model-driven bounds are seven tool
slots, two schema repairs and one suffix revision. Existing runtime call/iteration
limits, fixture backends and scoring are shared.

| Multi-step planner | Goals completed | Fixture calls completed | Grounded calls | Stop reasons |
|---|---:|---:|---:|---|
| Model-driven bounded v1 | 0/30 | 0/0 | undefined (no attempts) | 30 errors |
| State-machine open | 4/30 (13.33%) | 157/157 | 45/157 (28.66%) | 13 answer, 16 limit, 1 error |

Every model-driven trial ended with proposal semantic validation:
`arguments must be a valid bounded plan expression`. No tool executed. The
assessment is **inconclusive**, not a fabricated zero-percent tool rate. Initial
model proposals are not retained, so the exact malformed expression category
cannot be reconstructed from these reports. The state-machine assessment is
**belowTarget**, with 40/93 required steps matched. Answer termination alone is not
completion, and 100% fixture execution is not grounded success.

Single-tool: **91/100 schema-valid first calls (91%)**, nine text-only responses,
91/91 emitted calls schema-valid. Conditional emitted-call validity of 100% must
not hide the nine no-call probes. This is schema validity, not correct tool choice,
argument intent, real backend execution or an M5 pass. Earlier OS/provider reports
are not a causal baseline for these results.

[Raw reports, independent M5 replays, smoke and provenance](eval-results/2026-11-21-planner-macos)
retain all failures and source/binary/suite hashes. Offline model-driven replay
exits 3 for inconclusive; state-machine replay exits 2 for belowTarget. Native run
CLI exits were zero because misses/validation errors are measured outcomes;
those exit codes do not indicate successful agents. A plain executable-only copy
failed replay due to its missing SwiftPM bundle; replay succeeded after freezing
both executable and bundle. Original native reports were unaffected.

The model-driven smoke warmed the model; ordering was fixed rather than randomized.
Verification builds overlapped parts of execution. Raw elapsed times are retained
but are not controlled latency measurements. System-model asset identity is not
separately pinned beyond OS/toolchain/provider provenance. No user tools or data
were accessed. These are one-host observations and do not establish per-OS quality.

## iPhone host and completed acceptance

PlanningProbe compiles the same evaluation source files directly, with an app-bundle
resource shim and the exact Suites folder. This avoids exporting the internal
evaluation-support module as a new SDK product. It serially runs the same three
phases, uses fresh UUID report directories and without-overwriting writes, disables
idle lock only during a run, and cancels on backgrounding. It records start/end
thermal state but is not a continuous resource measurement. Missing phases or a
missing finished marker are incomplete evidence. Reports are compatible with the
CLI's offline replay; no simulator result can replace native generation.

The signed Debug iPhone build and installation pass; packaged fixture files were
checked before installation. Initial launch was blocked by the lock; after the
user unlocked the phone, the complete native protocol ran. Source/binary provenance
was captured before launch and source hashes rechecked on retrieval. CI now compiles this
host without signing or model generation and formats its source.

## Verification

Warning-free Swift build, full/default and network-denied SDK suites pass with
**847 registered functions**. Core/Runtime coverage is **98.91% (3533/3572)**,
up 0.06 percentage points from M5-02: Core 99.70% unchanged; Runtime 98.61%, up
0.08 points, with unchanged Runtime source. All 80 Python tests, strict changed-file
formatting, layering, actionlint, diff checks, strict DocC build and six-module
static routes (10,120 references) pass. Signed iPhone host compilation emits only
the existing AppIntents metadata warning. Native reports and proof hashes are
retained; all logs use `/tmp/lak-m503-*`.

## iPhone results and promotion decision

Physical iPhone 15 Pro (iPhone16,1), iOS 27.2 (24B115), signed Debug host. The fresh
run `4FFF785B-454D-4D6D-8BD7-D2CAA60E93C0` started at 11:07:36 UTC and finished
at 11:32:30 UTC on 2026-11-21. All three reports and the matching Finished marker
were retrieved only after the user reported completion. No user data was read.

| Multi-step planner | Goals completed | Fixture calls completed | Grounded calls | Stop reasons |
|---|---:|---:|---:|---|
| Model-driven bounded v1 | 0/30 | 117/117 | 55/117 (47.01%) | 26 error, 2 answer, 2 limit |
| State-machine open | 2/30 (6.67%) | 172/172 | 41/172 (23.84%) | 9 answer, 20 limit, 1 loop |

Both multi-step protocols are complete and both offline assessments are belowTarget;
each independent assessment exits 2. Required-step matches are 52/93 for
model-driven and 38/93 for state-machine. Model-driven failures include empty
results, oversized replacement suffixes, malformed literal JSON and limits.
Initial/revised proposals are not retained, so precise expression failures cannot
be reconstructed beyond the recorded error. Shared fixture acknowledgements can
be empty even after a matching write call. These results measure the deployed
planner/fixture protocol, not an isolated model's intrinsic reasoning quality.

Single-tool: **97/100 valid first calls (97%)**; 97 probes emitted 109 calls,
including 12 extras. 107/109 emitted calls were schema-valid (98.17%). The other
probes were two text responses and one timeout (st-06, repetition 1). All remain
in the denominator. Schema validity above 95% is not grounded multi-step success
or a real-tool M5 pass.

Thermal state was nominal at start and serious at end; intermediate transitions
were not sampled. The fixed phase order, sustained run, different hardware/OS,
Debug builds and unpinned model assets preclude causal OS or latency conclusions.
No failure or heated run was discarded to improve the score.

[Retained iPhone reports, independent replays and provenance](eval-results/2026-11-21-planner-ios)
include both terminal markers and hashes. Files were renamed for consistent
host-side replay; raw JSON bytes are unchanged. A parameterized offline regression
recomputes both OS M5 assessments and all single-tool validity fields without
trusting saved aggregates. The iPhone reports pass that replay.

**Decision: do not promote ModelDrivenPlanner.** It completed zero goals on both
sampled OS builds and neither planner's grounded fixture results meet the target.
Keep the state-machine default without claiming that its open mode is above the
bar. Future improvements require new versioned measurements rather than tuning on
these goals and reusing their results. M5-03's remeasurement/decision is complete;
real built-in-tool target verification remains separate. No energy, statistical
generalization, secure-data or performance improvement is claimed.
