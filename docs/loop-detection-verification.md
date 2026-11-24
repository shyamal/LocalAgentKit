# M5-09 — M8 loop-detection verification

Protocol 1, run 2026-11-24. Retained evidence:
[synthetic runtime report](eval-results/2026-11-24-loop-runtime.json).

M8 says “Agent detects repeated tool loops.” The bounded runtime behavior is verified
for the scenarios below. This is deterministic runtime evidence, not a native-model
loop frequency, general semantic classifier, or exhaustive proof of all possible cycles.

## Protocol

A private fixed planner emits the scenario's calls through the real AgentRuntime and
ToolExecutor. Fixture tools count actual executions independently of events. A private
gate approves only the verifier's synthetic write tool and counts approvals; it cannot
approve a caller-supplied or real user tool. An unused model actor counts generation
attempts and fails if invoked. All trials require zero model calls.

Each scenario runs three times on the same runtime, checking that loop history resets.
A full event stream is drained after all runs, then split by started events. Each trial
must have one terminal event, matching runtime/event stop reasons, expected execution
and approval counts, and matching requested/started/completed/observation counts. A
blocked serial call must not reach the executor; a rejected batch must not partially run.

## Scenario results

Each row passed three repetitions; counts are per run.

| Scenario | Expected stop | Executions |
| --- | --- | ---: |
| Exact A A A | loop | 2 |
| Alternating A B A B A | loop | 4 |
| A B C A B C A | loop | 6 |
| Integer/equivalent-double arguments | loop | 2 |
| Configured case/whitespace text normalization | loop | 2 |
| Declared equivalent phrases | loop | 2 |
| Semantic alternating cycle | loop | 4 |
| Three equivalent exact calls in one batch | loop | 0 |
| Three declared-semantic calls in one batch | loop | 0 |
| Two-call batch followed by repeating three-call batch | loop | 2 |
| Repeated synthetic confirmed write | loop | 2 (2 approvals) |
| One retry then finish | answer | 2 |
| Changing pagination argument | answer | 6 |
| Unknown paraphrases under configured policy | answer | 3 |
| Different paraphrases with exact-only policy | answer | 3 |
| Iteration limit before third repeat | iteration limit | 2 |
| Period four, outside runtime default | tool limit | 8 |

Total: 51/51 scenario contracts passed, comprising 33 intended loop detections,
12 negative controls and six boundary outcomes. The boundary outcomes are not counted
as detected loops. Their success means ordinary execution limits still stop the run.

## Reproduce

```bash
swift run LocalAgentKitEval verify-loops --repetitions 3 --output /tmp/loop-verification.json
```

The command exits unsuccessfully if any contract fails and always writes the completed
report first. Reports are schema 1, protocol 1, explicitly synthetic, with OS/time and
per-trial counts. They are separate from M5 model-quality assessments and supplemental
multi-step completion reports. CI runs the default verification in its synthetic CLI step.

## Limits

The runtime checks periods 1...3 by default. Standalone LoopDetector supports a larger
explicit period cap, but that is not silently enabled by this protocol. Unknown semantic
paraphrases, long cycles, outcome-based progress detection and intentional polling are
not covered by a general loop-detection claim. Text equivalences are application assertions.
No native model, battery, latency, real write or physical-device permission measurement
is involved. Existing M5-03 model-driven planning no-go evidence is unchanged.

## Validation

- Five harness test functions cover all contracts, event/execution counts, reuse, report
  encoding/decoding, batch rejection, approvals, boundary classification, invalid options
  and pre-cancellation.
- Full and offline suites: 906 registered functions passed.
- Thread Sanitizer: 42 harness/loop/semantic-runtime/parallel-tool functions passed without
  reported races.
- Warning-free build, strict changed-file formatting, layering and whitespace checks passed.
- Core/Runtime coverage: 98.82% (3936/3983), unchanged from M5-08. Core 99.80%
  (993/995), Runtime 98.49% (2943/2988). No gated engine source changed.
- DocC build and static routes passed: six modules, 10,529 internal references.
