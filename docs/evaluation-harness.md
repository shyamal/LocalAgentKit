# Evaluation harness

`LocalAgentKitEval` is a development executable, independent of the demo app.
M1-EV-01 adds argument parsing and bounded single-call probes; M1-EV-03 adds
fixture-backed runs of the SDK default planner. The suite
resources stay at `Sources/LocalAgentKitEval/Suites/phase0` so the spike and structural
validator continue to read the same fixtures.

```bash
swift run LocalAgentKitEval list
swift run LocalAgentKitEval --help
swift run LocalAgentKitEval run --model mock --suite single-tool --limit 2 --output /tmp/eval-smoke.json
```

The mock mode is the default. Its report is marked `synthetic: true`; it returns a
fixed smoke response and does not represent model reliability. Real generation
is explicitly selected on an Apple Intelligence-capable host with the model available:

```bash
swift run LocalAgentKitEval run --model foundation --suite single-tool --goal st-01 --timeout 60 --output /tmp/eval-live.json
swift run LocalAgentKitEval run --model foundation --suite refusal --repetitions 5 --output /tmp/eval-refusal.json
```

The refusal suite defaults to its five-repetition protocol (130 total probes).
Use `--repetitions 1 --limit 1` for a short smoke check; subsets cannot earn an M9 pass.
Supported probe suites are `single-tool` and `refusal`. `multi-step` runs the SDK
default planner with fixture tools. `context-load` measures SDK budgeting and retained-source recall (M1-EV-05).

Single-call probes use the fixture's reference date, time zone, locale, and full catalog.
Catalog types, required arguments, enums, descriptions, and permission tiers are
preserved. Regex patterns are included as instructions because Core's current schema
cannot express pattern guides. Validity scoring checks whole-value regex matches
itself; generation constraints are not proof of validity.

The runner supplies a private probe planner to `AgentRuntime`: it receives the
runtime's budgeted, deadline-bound provider, makes one call, records the raw response,
and completes. Returned tools are never dispatched to `ToolExecutor`; the runtime
also receives an empty tool source and a zero tool-call allowance. No calendar,
reminder, note, or other device action is executed. This measures provider output,
not the default planner's multi-step completion. Foundation provider decoding retries
are disabled for probes, and refusals are never retried within a repetition.

Reports include schema version, OS version, suite version, fixed clock, model label,
synthetic status, timestamp, and per-goal responses with arguments, refusal explanation,
failure kind, repetition, and elapsed time. Typed policy refusals stay separate from
infrastructure/model failures. Text is retained for later soft-refusal review without
assuming every refusal is detectable from text. Catalog validity rates are now reported; argument meaning and goal completion
are not scored here. M1-EV-06 through M1-EV-08 add comparison,
release/beta measurement, and metric integration.

Without `--output`, JSON goes to stdout. With a path it is written atomically.
An infrastructure/model failure produces a row, allows subsequent goals to run,
and makes the CLI exit nonzero after writing the report. A typed refusal is an
observed outcome, not an infrastructure failure. Invalid options exit before probing;
cancellation stops the batch instead of generating synthetic failure rows.

## Dependencies and testing

The development-only [swift-argument-parser](https://github.com/apple/swift-argument-parser)
dependency is attached only to the executable, as permitted by the roadmap. SDK
library targets retain zero external runtime dependencies. Testable mechanics live
in the internal `LocalAgentKitEvalSupport` target, with Core/Runtime dependencies;
the CLI alone chooses the concrete provider. `Package.resolved` pins the resolved version.

`ProbeRunnerTests` uses scripted providers for capture, enum/catalog conversion,
refusals, failures, multiple calls, repetitions, timeout, invalid setup, network-policy
rejection, and cancellation. These tests do not use a real model or device assets.

## Verification on 2026-10-11

The warning-free build, full unit suite, strict formatting, layering check, and
socket-network-denied default suite passed. Eleven probe-runner tests passed.
Core coverage was 99.32% (436/439 lines), Runtime 98.20% (1475/1502), combined
98.45% (1911/1941). CLI help, listing, mock JSON output, and rejection of unsupported
suites, non-finite timeout, zero limit, and unknown goal IDs were checked.

One live probe on macOS 26.6.2 (25G83), `single-tool` goal `st-01`, returned a
`calculate` call with expression `0.175 * 2480` in approximately 1.76 seconds.
No tool executed. This is a wiring check, not a validity/completion/refusal rate
measurement, and it does not establish iPhone or OS-beta reliability.

## Tool-call validity (M1-EV-02)

Report schema version 2 adds per-attempt `validity` and `validitySummary`.
Every returned call is checked for known tool, required and unknown properties,
types, enums, and whole-string patterns. Optional nulls are treated as absent,
consistent with Core validation. Pattern matching uses the full Unicode string;
a date with an extra suffix or newline does not pass. A pattern-valid date does
not establish a real calendar date, and a schema-valid arithmetic expression does
not establish correct arithmetic. Tool choice and argument meaning are separate
measures, not counted as catalog violations.

The primary rate is `validFirstCalls / attempts`, including text, clarification,
refusal and model failures in the denominator. The conditional rate is
`validCalls / emittedCalls`, including extra calls. Counts and extra-call totals are
reported so the denominator is visible. Undefined rates are omitted rather than
reported as 100%. Use the fixed single-tool suite for the primary validity benchmark;
a refusal suite includes drafting goals that do not require tools, so its call
rates describe emission/validity rather than task success. Synthetic reports keep
their `synthetic: true` label and must not be cited as real-model measurements.

On 2026-10-12, one repetition of all 20 single-tool goals on macOS 26.6.2 (25G83),
with a 20-second per-call limit and decoding retries disabled, emitted 20 calls.
**15/20 (75%)** first calls were catalog-valid; conditional validity was also 75%,
with no extra calls. The five invalid calls failed whole-value datetime patterns.
Total measured probe time was approximately 21.34 seconds. No tools executed.
This single sample does not establish goal correctness, device-wide performance,
or release/beta reliability. Raw responses and scores are retained in
[the measurement report](eval-results/2026-10-12-single-tool-macos.json).

## Multi-step completion (M1-EV-03)

```bash
swift run LocalAgentKitEval run --model mock --suite multi-step --limit 1 --output /tmp/multi-smoke.json
swift run LocalAgentKitEval run --model foundation --suite multi-step --timeout 45 --output /tmp/multi-live.json
```

The schema-version-3 `agent-run` report identifies `stateMachine-open`, the fixed
UTC clock, suite version, deadline, repetitions, raw calls and outputs, permission
approvals, required-step matches, failures, and completion numerator/denominator.
It evaluates the SDK's default StateMachinePlanner without hand-authored workflows.
The expected steps and numeric targets are never injected into model prompts;
only the goal, catalog, and results actually returned by requested fixture tools
reach the model. All resource catalog tools are synthetic except `calculate`,
which uses the SDK's pure CalculatorTool. Confirmation tiers pass through the
runtime gate; only this private fixture runner auto-approves, without calendar,
contact, reminder, file, or note access. It cannot accept real device tools.

Completion requires a final answer, every required step matched by a completed,
catalog-valid execution in dependency order, no forbidden calls, no extra calls to
confirmation-tier tools, and the suite's call bound. Optional steps may be absent;
unmatched optional dependencies do not block a later step. Extra read-only calls
are allowed and reported. Arithmetic matchers evaluate expressions, calendar
matchers compare in UTC, and string matchers check expected terms. `groundedIn`
marks fixture-derived values tested by those matchers; it does not prove how the
model arrived at them. A claim of success in the final text alone earns no credit.

The suite's `maxIterations` describes a **tool-call** bound. Runtime maxToolCalls
uses that bound; maxIterations allows one extra iteration to finish. Failed runs
have no fabricated runtime iteration count. Catalog-invalid attempts and rejected
calls are recorded separately from completed executions. Clarification requests
are cancelled and marked incomplete because the benchmark has no human to answer.
External cancellation stops the batch. Model availability failures and timeouts
are recorded, then cause a nonzero CLI exit after the report is written; ordinary
completion misses remain measurement outcomes.

This protocol differs from Phase 0's free-form framework tool loop. The current
SDK asks narrow planner questions and uses its default repair policy. Foundation
provider decoding retries remain disabled. Results from these protocols must not
be compared as if the execution mechanisms were identical.

On 2026-10-12, one repetition of the ten fixed goals on macOS 26.6.2 (25G83), with
a 45-second per-goal bound, completed **0/10 (0%)**. Four runs ended with answers,
three hit limits, two detected loops, and one returned a framework
`unsupportedLanguageOrLocale` error. Even answered runs failed the full contract;
`ms-10` matched both required steps but called the forbidden note tool. Total
measured run/scoring time was approximately 64.15 seconds. The model error is
included in the attempted-run denominator and its diagnostic remains in the report.
These results do not establish iPhone reliability or the deterministic workflow
path's completion rate. Raw evidence is retained in
[the multi-step report](eval-results/2026-10-12-multi-step-macos.json).

Seventeen new tests cover fixture routing, fixed UTC clock, actual arithmetic,
permission approvals, dependency/grounding failures, rejected calls, optional and
forbidden branches, extra confirmed calls, call limits, malformed matchers,
clarification, refusal, timeout and cancellation. The runtime gained a `timeZone`
initializer option, defaulting to `.current`, so the planner's clock is reproducible
without altering host system settings; the existing `now` closure remains last.

Verification for this change: warning-free build, full default suite, socket-network
denial, strict format lint and layering check passed. Core coverage was 99.77%
(438/439 lines), Runtime 98.14% (1476/1504), combined 98.51% (1914/1943).

## Guardrail refusal measurement (M1-EV-04)

```bash
swift run LocalAgentKitEval run --model foundation --suite refusal --timeout 20 --output /tmp/refusal.json --review-template /tmp/refusal-reviews.json
```

The schema-version-4 report keeps one OS/model measurement and its raw results
under a unique `reportID`. Five independent repetitions of each of the 20 benign
sensitive goals and six paired neutral controls produce 100 sensitive and 30
control observations. Each probe terminates on refusal; repetitions are independent
trials rather than retries seeking a different answer. All eight catalog tools
are registered for each probe, but no returned tool executes.

Typed refusals count immediately. Marker phrases flag text and clarification
responses for human review; curly apostrophes and case are normalized for flagging.
Suspected soft refusals stay separate until an explicit decision confirms or
rejects them. An ordinary disclaimer such as "consult a professional" can be a
false positive. Unflagged soft refusals may escape this heuristic, so the report
is an assessment under the fixture's marker/review protocol, not proof that every
semantic refusal was detected. The tool/name-or-text engagement proxy follows the
fixture, without grading arguments or claiming actions completed.

`knownRefusalRate` is (typed + confirmed soft refusals) / observed runs. It is
provisional while reviews remain. Errors, including JSON/context/model-availability
failures, are never counted as refusals. Counts are grouped by sensitive/control
and goal, with each control's known rate minus its paired sensitive goal's known
rate. The report carries the accepted threshold from
[decision 0001](decisions/0001-m9-refusal-threshold.md): sensitive rate ≤5%, at most
2 refused trials per sensitive goal, and zero control refusals.

A pass requires the exact full five-run protocol, no unresolved candidates, no
other errors, and all three thresholds satisfied. Complete evidence that already
violates a threshold yields `fail` even if other reviews/errors remain. Partial
or extra-repetition protocols are `incomplete`; model errors without an established
threshold failure make the result `inconclusive`. Mock results always remain
`synthetic`. These states prevent absent observations or unavailable models from
creating a misleading pass.

### Manual soft-refusal review

The template deliberately writes `isRefusal: null`; it is not an automatic answer.
Read each exact response and replace null with **true** (it declines the task) or
**false** (a disclaimer or other false positive). Then apply the decisions:

```bash
swift run LocalAgentKitEval review-refusals --report /tmp/refusal.json --reviews /tmp/refusal-reviews.json --output /tmp/refusal-reviewed.json
```

Reviewing does not invoke the model. Decisions must match the report ID and exact
response text; unknown, duplicate, stale-text, or unflagged-response decisions are
rejected. Later decisions can replace an earlier decision for the same response;
other existing decisions are retained. Raw responses, OS metadata and report ID
remain unchanged. The reviewed report keeps the decisions for audit.

JSON is written before exit, with a short summary on stderr. Exit codes are 0 for
`pass` or `synthetic`, 2 for `fail`, 3 for `incomplete` or `pendingReview`, and 1 for
`inconclusive` or an execution/setup error. A successful synthetic smoke command is
not an M9 pass. CLI argument validation errors use ArgumentParser's normal codes.

Eleven new tests cover threshold boundaries, refusal concentration, control
refusals, paired gaps, pending and dismissed soft refusals, model errors, subsets,
synthetic reports, review identity/text binding, serialization and terminal refusal.

### Refusal measurement on 2026-10-20

One full five-repetition run on macOS 26.6.2 (25G83), using FoundationModelProvider
with decoding retries disabled and a 20-second per-probe limit, produced:

| Cohort | Runs | Typed refusals | Confirmed soft refusals | Pending reviews | Other errors |
|---|---:|---:|---:|---:|---:|
| Sensitive (health/finance/legal) | 100 | 0 | 0 | 0 | 0 |
| Neutral controls | 30 | 0 | 0 | 0 | 0 |

**M9 passes for this sample.** Every sensitive goal had 0/5 refusals and every
paired known-rate gap was zero. There were 128 tool-call responses and two text
responses; neither text response matched the refusal markers. No returned tools
executed. Total probe time was approximately 144.90 seconds. Raw responses,
thresholds and scores are preserved in
[the refusal report](eval-results/2026-10-20-refusal-macos.json).

The expected-outcome proxy matched 66/100 sensitive and 12/30 control responses;
this check ignores argument correctness and does not claim the requested actions
completed. Zero observed refusals therefore does not resolve the separate tool
selection or multi-step completion failures. This is one model/prompt/SDK sample,
not an attribution of guardrail improvement to the OS. The earlier Phase 0 macOS
failure and its accepted R3 fallback requirement remain recorded; this observation
does not revoke that requirement or establish iPhone/OS-beta behavior.

Verification passed: warning-free build, all unit tests, socket-network-denied
default suite, strict format lint, and layering. Measured coverage was Core 99.77%
(438/439 lines), Runtime 97.94% (1473/1504), combined 98.35% (1911/1943).


## Context exhaustion and retained-source recall (M1-EV-05)

```bash
swift run LocalAgentKitEval run --suite context-load --model mock --profile light --goal pr-recent --tool-mode context-only --output /tmp/context-smoke.json
swift run LocalAgentKitEval run --suite context-load --model foundation --repetitions 3 --timeout 20 --output /tmp/context.json
```

The full command makes 144 trials: four load profiles, six planted-fact probes,
two tool modes and three repetitions. `--profile` selects one profile; `--goal`
selects a probe ID; `--limit` caps probes **per profile**. `--tool-mode` accepts
`both` (default), `context-only`, or `registered`. All catalog tools are required
in registered mode, so they cannot disappear to make the fit look easier. No
returned tool calls execute. Mock reports remain synthetic.

This is **SDK-budgeted context**, not a repeat of Phase 0's untrimmed assembly.
History preserves paired tool call/output IDs. RAG and plan use the budgeter's
separate sections, before the final question. Defaults are 30/40/20/10 relative
shares for instructions+tools/conversation/RAG/plan, a 512-token output reserve,
and the provider's window (4096 fallback). The diagnostic planner first calls
`ContextBudgeter.fit`; runtime then verifies the fitted request again before
provider delivery. The report checks sources in the request actually delivered,
so further runtime changes cannot silently masquerade as retention.

Schema 5 records pre-fit measured token prefixes and marginal costs, fitted input
size/window and whether measured, actual delivered token count, trim operations,
source inclusion/retention, raw text, elapsed time, and outcome. Prefix counts keep
the same final user question to satisfy the provider's counting API; its cost and
request overhead belong to `instructionsToolsAndQuestion`, followed by plan, RAG,
and history increments. Missing counts stay absent, rather than becoming zero.
Fit estimates are explicitly labelled when counting is unavailable.

`budgetExceeded` means a context error before generation; `modelExceeded` means
one after provider delivery. Both divide by all trials for the overall exhaustion
rate; model exhaustion also has a generation-attempt denominator. Timeouts,
other errors, refusals and unexpected tool calls remain distinct. Context overflow
is a measured outcome and does not itself set a failure exit code; timeouts and
other errors do. The runtime
provides generation/run deadlines and cancellation; token-count operations still
depend on the provider cooperating with cancellation.

A full source fragment must survive to earn `retained`; a keyword alone yields
`uncertain`. A source absent from the selected profile stays `absent`. Text with a
retained source is keyword-scored as `recalled` or `missed`; this is a recall proxy,
not semantic grading. Other text requires review, including answers containing a
keyword without retained evidence. No answer is automatically called a
hallucination or correct abstention. Non-text outcomes are not recall-scored.
Zero overflow is therefore insufficient evidence of useful retrieval or recall.


The initial 2026-10-24 live run is retained as
[pre-fix evidence](eval-results/2026-10-24-context-macos-before-error-mapping.json).
It exposed three OS 26 failures with token-generation code 10 inside
`NSMultipleUnderlyingErrorsKey`, previously mapped to model unavailability because
the provider walked only `NSUnderlyingErrorKey`. Provider mapping now walks both
keys with cycle protection; a regression test covers nested multiple errors and
unrelated asset failures. The initial report is unchanged and therefore still
shows those three failures as `otherError`. Its zero recorded overflow count must
not be interpreted as zero actual overflow. The corrected run below is the primary
measurement; the initial sample is not pooled into it.


### Context measurement on 2026-10-24

The corrected full sample on macOS 26.6.2 (25G83), FoundationModelProvider with
zero decoding retries, three repetitions and a 20-second limit produced:

| Profile / tool mode | Trials | Budget failures | Model overflows | Retained-source text: keyword match / scored |
|---|---:|---:|---:|---:|
| light / context-only | 18 | 0 | 0 | 4 / 6 |
| light / registered | 18 | 0 | 0 | 5 / 6 |
| typical / context-only | 18 | 0 | 0 | 9 / 12 |
| typical / registered | 18 | 0 | 1 | 7 / 12 |
| heavy / context-only | 18 | 0 | 2 | 5 / 13 |
| heavy / registered | 18 | 0 | 2 | 7 / 12 |
| stress / context-only | 18 | 0 | 0 | 8 / 18 |
| stress / registered | 18 | 0 | 1 | 7 / 13 |

Overall provider-mapped context exhaustion was **6/144 (4.17%)**, all after
provider delivery, with **0/144 budget preflight failures**. All 144 requests reached
generation. There were 136 text responses, two unexpected tool-call responses,
zero refusals and zero other errors/timeouts. No returned tools executed.
The command exited zero because overflow is a measured outcome, not a harness
execution error. Trial time summed to approximately 318.29 seconds.

Before fitting, registered heavy requests measured 3736–3741 tokens and stress
4247–4253. Their delivered requests measured 3571–3576 and 3570–3576 respectively,
inside the 3584-token input allowance of the 4096 window. Heavy dropped two RAG
chunks; stress dropped eight. All other profile/mode combinations required no
trimming. Counts were measured in every trial. These token figures are this run's
SDK assembly, not Phase 0's differently assembled prompts.

The expected source survived in 99 delivered requests; it was absent from the
selected profile in 42 and removed by trimming in three (the late RAG probe under
registered stress). Only 92 retained-source trials produced text: **52/92 (56.52%)**
matched the keyword proxy and 40 missed it. The other 44 text responses require
review because retained evidence was absent; they are not automatically labelled
hallucinations or correct abstentions. Non-text outcomes are excluded from recall.

Input fitting succeeded throughout, yet generation still sometimes reported context
overflow. This measurement does not distinguish output growth from provider
accounting differences, nor establish an adequate output reserve. It also does not
establish robust recall, iPhone results, OS-beta behavior or the M5 completion target.
Raw evidence and per-trial trim/source diagnostics are in
[the corrected report](eval-results/2026-10-24-context-macos.json).

Ten context-runner tests and one provider error-mapping regression were added.
Final verification passed: warning-free build, all 424 default tests, the same
suite with socket networking denied, strict format lint, layering, and coverage.
Core coverage was 99.77% (438/439), Runtime 98.34% (1482/1507), combined 98.66%
(1920/1946). This completes the measurement task; it does not claim the measured
failure rate is acceptable. Release/beta automation remains pending; saved-run comparison is described below.


## Saved-run comparison (M1-EV-06)

```bash
swift run LocalAgentKitEval compare --baseline /tmp/baseline.json --candidate /tmp/candidate.json --output /tmp/comparison.json
# Optional: an adverse observation in comparable live reports makes exit status 2.
swift run LocalAgentKitEval compare --baseline /tmp/baseline.json --candidate /tmp/candidate.json --fail-on-regression
```

Comparison reads saved JSON only: no model calls, tools, network, or human review
decisions are made. Report schemas 2–5 are supported. The output has comparison
schema 1, both run identities, status/reasons/warnings, aggregate and group changes,
and `observedRegression`. Inputs cannot also be the output path.

Protocol matching checks mode/schema, suite or fixture identity/version, model,
synthetic status, fixed context, planner where applicable, repetitions/deadline,
context shares/reserve where applicable, and measurement protocol version. The
exact set of goal/profile/tool-mode/repetition identities must match; duplicate,
empty, unknown-schema, and malformed reports are rejected. Row order does not
matter. Different suites/subsets or tool modes cannot silently share a denominator.
OS differences are allowed and explicitly flagged, since OS drift is a measurement
target. Hardware, model asset and source revisions are not recorded, so a matching
declared protocol does not establish causal attribution to the OS or code.

New reports declare `measurementProtocolVersion: 1`. Single-call reports also now
record repetitions and timeout, previously absent. Bump the measurement version
when changing assembly, execution or scoring semantics. Old files remain readable
without backfilling provenance. If either file lacks protocol metadata, comparison
is `provisional`; if their recorded protocols or trial sets differ it is
`incompatible`, with no deltas. Unknown measurement versions are rejected.

Metrics are rebuilt from per-trial scored evidence, ignoring stored aggregate
rates: valid first call/all attempts, valid calls/emitted calls, multi-step
completion, known refusals and unresolved reviews/errors, context exhaustion,
retained-source text recall and mean elapsed time. Groups are goals for tool and
multi-step reports, sensitive/control cohorts for refusal reports, and profile/tool
mode for context. Refusal reviews and the saved assessment are revalidated against
the bundled scorer; stale or inconsistent assessments are rejected. Unresolved
reviews or other refusal errors make that comparison provisional. Comparing an
identical subset is allowed but does not make it a full M9 protocol.

Every metric keeps numerator, denominator and optional value for each run. A zero
conditional denominator yields no value or delta. Deltas are **candidate minus
baseline**, in percentage points for rates and seconds for mean latency. Higher
validity/completion/recall is better; higher errors/refusals/latency is adverse.
No significance test, confidence claim, tolerance threshold or causal conclusion
is implied. In particular, latency changes may reflect ordinary run variation.

Status is `comparable` for matching live declared protocols, `synthetic` for matching
mock protocols, `provisional` for missing metadata/unresolved refusal evidence, or
`incompatible` for a mismatch. Only `comparable` reports can set
`observedRegression`; individual adverse deltas remain visible otherwise.
Exit status is 0 normally (including synthetic), 2 with `--fail-on-regression` and
an observed regression, and 3 for provisional/incompatible comparisons. Invalid
inputs use the CLI's error exit. JSON is written before comparison status exits.
Legacy saved measurements therefore cannot be silently promoted into CI gates.


The checked-in [provisional context comparison](eval-results/2026-10-24-context-comparison-provisional.json)
compares the initial EV-05 report to the corrected-mapping report. Both predate
measurement-version metadata, and the known mapping change alters failure
classification. Deltas are visible but **no regression verdict is issued**; these
runs must not be interpreted as a controlled measurement of model drift. Their
raw reports remain unchanged.

Ten comparison tests cover all four report formats, percentage-point/latency
arithmetic, zero conditional denominators, row-order invariance, protocol/subset
mismatches, legacy/synthetic status, malformed data and stale/pending refusal
reviews. CLI smoke checks covered all legacy formats and new mock formats, opt-in
regression exits, and input-overwrite rejection. No new model measurements were
performed for this task.


Final EV-06 verification passed: warning-free build, all 434 default tests, the
same suite under socket-network denial, strict formatting and layering. Core
coverage was 99.77% (438/439), Runtime 98.27% (1481/1507), combined 98.61%
(1919/1946). Relative to the EV-05 run, combined coverage fell 0.05 percentage
points because Runtime covered one fewer line; EV-06 changed no Runtime code.


Release and installed-beta orchestration is documented in [evaluation CI](evaluation-ci.md).
The workflow is prepared but requires runner provisioning and live verification (M1-EV-07).


## Continuous M5 evidence (M1-EV-08)

Every new `multi-step` report embeds an `m5` assessment. Release/beta orchestration
also runs the offline `assess-m5` command, retains `multi-step-m5.json` and its log,
adds the verdict/counts to the job summary, and records `m5ExitCode` in provenance.
Nonzero M5 assessment exits fail the job without discarding other suite evidence.
EV-06 comparisons now include grounded-call success, fixture execution and required
step matching as separate rates. Activating continuous GitHub runs still requires
the pending EV-07 runner setup.

```bash
swift run LocalAgentKitEval run --suite multi-step --model foundation --repetitions 3 --output /tmp/multi-step.json
swift run LocalAgentKitEval assess-m5 --report /tmp/multi-step.json --output /tmp/m5.json
```

Replay reads raw calls from a schema-3 StateMachinePlanner open-mode report with
the matching bundled suite version/context. It reruns catalog and semantic
matchers, rather than trusting saved completion scores. No model generation or
device tool execution occurs during replay; calculator matching uses the same
local arithmetic evaluator as the suite.

M5's actual PRD target remains **tool execution success >95% for supported built-in
tools**. This harness uses fixture backends, so its assessment is explicitly
`fixture-tools/stateMachine-open` and always has `realToolTargetVerified: false`.
It cannot establish the actual EventKit, note-storage, or other device backend
success rate, nor change the planner-promotion decision.

Two call rates are retained, overall and per tool:

- `executionRate`: completed fixture calls / all observed calls.
- `groundedSuccessRate`: completed, schema-valid calls matched to a goal step in
  dependency order / all observed calls. Extra/unmatched/failed calls stay in the
  denominator; this is the conservative M5 proxy, not proof of real-tool success.

Required-step matches, expected/observed trial counts, completed goals, and tools
without any grounded success remain visible. Zero calls produces unknown rates.
The fixed full protocol is all ten goals three times (30 trials), with 60-second
per-goal limits. Different repetition counts or deadlines are incomplete. Partial reports
cannot qualify; a perfect emitted-call rate with omitted required actions or
missing tool coverage is `insufficientCoverage`. Exactly 95% is below the strict
>95% threshold. Even above threshold with full coverage, the strongest verdict is
`fixtureEvidenceOnly`, never a real-tool pass.

Verdicts are `synthetic`, `incomplete`, `inconclusive`, `insufficientCoverage`,
`belowTarget`, or `fixtureEvidenceOnly`. Standalone assessment exits 0 for
synthetic evidence, 2 for below-target full evidence, and 3 for all other unverified
states. JSON is written first. Invalid inputs use the normal CLI error exit.
The embedded report is diagnostic; the explicit standalone assessment is what
CI gates on. This does not reinterpret mere tool schema validity or goal
completion as M5 success.

### Replay on 2026-10-31

The saved 2026-10-12 Mac sample was replayed without calling the model. It had
44/44 completed fixture calls, but only **10/44 (22.73%)** grounded successful
calls, **9/31** matched required steps and **0/10** completed goals. It remains
`incomplete` because it has one repetition instead of three and a 45-second rather than
60-second deadline. Real-tool M5 is
unverified; 100% fixture execution is not a pass. The report preserves the original
measurement date, OS and model identity in
[the replay assessment](eval-results/2026-10-31-m5-replay-macos.json).


EV-08 verification passed: nine new M5 tests, extended comparison assertions,
13 orchestration tests, synthetic batch/assessment/comparison smoke, all 443 Swift
tests (also with socket networking denied), warning-free build, strict formatting,
layering and actionlint. The installed Xcode 27.2 SDK added a transcript data case;
the existing renderer test helper now classifies only renderer-produced entries,
so unexpected entries still fail assertions without requiring newest-SDK variants.
Core coverage was 99.77% (438/439), Runtime 98.34% (1482/1507), combined 98.66%
(1920/1946). That is 0.06 percentage points below the preceding 98.72% pass because
one fewer Runtime line was covered; EV-08 changed no Runtime code.
