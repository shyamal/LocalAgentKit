# Evaluation harness

`LocalAgentKitEval` is a development executable, independent of the demo app.
M1-EV-01 adds argument parsing and a bounded single-call probe runner. The suite
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

The refusal fixture calls for five repetitions per goal; the CLI defaults to one
so smoke runs are short. Set `--repetitions 5` for that measurement protocol.
Supported probe suites are `single-tool` and `refusal`. `multi-step` and
`context-load` remain listed but cannot be run by this initial single-call runner;
their execution and scoring belong to M1-EV-03 and M1-EV-05.

Every probe uses the fixture's reference date, time zone, locale, and full catalog.
Catalog types, required arguments, enums, descriptions, and permission tiers are
preserved. Regex patterns are included as instructions because Core's current schema
cannot express pattern guides. Later validity scoring must check whole-value regex
matches itself; generation constraints are not proof of validity.

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
assuming every refusal is detectable from text. No correctness or reliability rates
are claimed in this version; M1-EV-02 through M1-EV-08 add scoring, comparison,
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
