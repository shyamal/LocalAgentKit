# Model-proposed conditional workflows (M5-01)

Implemented and verified on 2026-11-20. The experimental `.modelDriven` planner now
asks for a complete ordered conditional workflow before any proposed tool executes.
The default remains `.stateMachine`; no real-model reliability claim or promotion
is made. Replanning remains M5-02 and fresh per-OS measurement remains M5-03.

## Proposal and execution

The existing required tool/summary/instruction fields remain compatible. Optional
argument expressions select a model hint, a JSON literal or an earlier generated
step binding. The catalog includes parameter names, required/optional status,
types and descriptions. Literal JSON is bounded to 16,384 UTF-8 bytes and checked
against the target parameter schema. Duplicate/unknown parameter names, malformed
literals, self/forward/unknown bindings and malformed paths reject the whole plan.
References only resolve earlier `step_N` result bindings, not arbitrary memory,
attachments or executable expressions.

Up to eight flat conditions per step use presence, emptiness, equality or finite
numeric thresholds, combined with all/any. Conditions run in the existing workflow
interpreter. Complementary guards select conditional paths within an ordered plan;
this is not parallel or DAG scheduling. The model may propose zero through two
extra retries and fail/skip empty-result policy. Permission denial, refusal,
cancellation and execution limits remain terminal. The existing loop detector
can stop before a declared retry bound: the third identical call remains a loop.

The whole proposal compiles and validates before context mutation or tool execution.
Generated-plan bindings are additionally type checked before per-step resolution,
so missing or incompatible observed values fail without model substitution. This
check is scoped to ModelDrivenPlanner: existing declared workflow argument-repair
behavior remains unchanged. Partial model-generated arguments still use bounded
schema repair. All model calls retain runtime budgeting, deadlines and cancellation;
every executed tool retains validation and permission gating. `.planCreated`
continues to publish the proposed steps; no new public API or dependency was added.

## Verification

Ten new functions bring the targeted planner suite from 13 to 23 functions. The
parameterized cases cover all eight guard operators and twelve malformed proposal
variants. End-to-end scripted runs verify structured-result grounding without an
argument-generation call, conditional paths, empty-result fallback, missing and
incompatible bindings, JSON literals, retry recovery, permission denial and loop
protection. Existing planning refusal, budget, cancellation, deadline, execution
limit and default-selection checks remain passing.

The initial retry test hit the expected third-identical-call loop stop; the final
suite explicitly checks that safeguard rather than weakening it. An initial shared
binding-validation change broke three declared-workflow repair regressions. Moving
the check into the generated-plan path restored those tests; no existing test was
removed or disabled. Final gates:

- Warning-free Swift build and full/default + network-denied SDK suites:
  **832 registered functions**, including all 23 planner functions.
- Core/Runtime line coverage **98.86% (3473/3513)**, above the 80% gate. Versus the
  most recent measured M4-09 result (98.95%), overall coverage is down 0.09 percentage
  points. Core is 99.70% (981/984), up 0.11 points; Runtime is 98.54% (2492/2529),
  down 0.15 points with the new compiler and generated-binding validation.
- Demo 45, EmbeddingProbe seven and resource probe six portable functions pass;
  all 80 Python tests pass.
- Strict changed-file formatting, layering and diff checks pass.
- Strict DocC build and static route check pass: six modules, 10,111 internal
  topic references. Documentation describes the proposal language and limits.
- Generic iOS demo build succeeds; existing AppIntents/orientation warnings remain.
  No signing settings or device data are committed.

Logs are `/tmp/lak-m501-*`; the final full-suite/coverage and offline reports are
`/tmp/lak-m501-final2-coverage.log` and `/tmp/lak-m501-final2-offline.log`.
No native model run, success-rate measurement, energy measurement or independent
quality annotation was performed. Tests establish bounded execution semantics,
not that a compact model will choose the right plan, literals or guards. Earlier
state-machine benchmark results must not be attributed to this configuration.
