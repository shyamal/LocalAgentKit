# Bounded model-driven replanning (M5-02)

Implemented and verified on 2026-11-20. The experimental model-driven planner can
replace its unfinished suffix after an exhausted tool failure or unexpected empty
result. The state-machine default is unchanged; no real-model reliability or
promotion is claimed. M5-03 remains the measurement gate.

## Contract

`ModelDrivenPlanner(maxSteps:maxRepairs:maxReplans:)` defaults to one revision per
run, with maxReplans clamped to zero through three. Zero retains the prior
fail-without-revision behavior. Declared retries and empty-result skip run before
model recovery. Only typed toolFailed requests a revision. Denial, refusal,
cancellation, invalid bindings, loop detection and execution limits remain terminal.
Exhausted invalid-argument errors never trigger a new plan; existing schema repair
and declared argument retries still apply. Successful nonempty results do not incur a semantic-assessment
query; this implementation detects unexpected outcomes through failures/emptiness.

Synchronous observation/failure handling records a pending reason in AgentContext.
The next async decision asks the runtime-budgeted model for a replacement suffix,
using the same schema, repairs, deadlines and context fitting as initial planning.
The completed prefix and full typed facts remain in context. Empty observed calls
retain a real empty binding and advance into the prefix; failed calls do not create
facts. New step numbers continue after the prefix, allowing exact earlier-result
references. Combined completed/proposed tool slots remain within maxSteps. An
invalid suffix fails before any replacement execution or revised-plan publication.

The revised catalog excludes confirmation/sensitive tools already attempted,
including failures with uncertain side effects. Completed protected prefix steps
remain valid in the displayed workflow but are never replayed by the interpreter.
An attempted protected tool cannot be proposed again even with changed arguments.
New protected tools retain normal human authorization. Read-only retries still
face the unchanged loop detector; no revision resets history or budgets.

`PlannerDecision.revisePlan` carries the validated combined plan. AgentRuntime
publishes `.planCreated` and resumes execution on the following iteration. The
revision decision consumes an iteration; tool/model-call, duration and context
limits continue across it. Custom drivers with exhaustive PlannerDecision switches
must handle the new case. The existing synchronous PlanRevision API remains.
The planner holds only immutable configuration; counters/reasons live per run in
AgentContext, with fresh budgets across subsequent runs.

## Evidence

Twelve new test functions bring the planner suite to 35. Scripted integration
checks verify suffix replacement, preserved facts and completed work, revised-plan
events, unexpected emptiness, exhaustion, completed/uncertain protected-tool replay
rejection, new protected-tool denial, refusal, cancellation, model-call timeout,
remaining-step/iteration/tool-call budgets and independent revision counts across
runs. The previous fail-without-replanning check now explicitly selects zero
revisions, preserving coverage of the opt-out contract. No test was removed.

Final checks:

- Warning-free Swift build; full/default and network-denied SDK suites pass with
  **844 registered functions**, including all 35 planner functions.
- Core/Runtime coverage **98.85% (3531/3572)**: Core 99.70% (981/984), unchanged;
  Runtime 98.53% (2550/2588), down 0.01 percentage points. Combined coverage is down
  0.01 points from M5-01 and remains above the 80% gate.
- Demo 45, EmbeddingProbe seven, resource probe six and all 80 Python checks pass.
- Strict changed-file formatting, layering and diff checks pass.
- Strict DocC build and static routes pass: six modules, 10,976 internal references.
- Generic iOS demo build succeeds, with existing AppIntents/orientation warnings.

Logs are `/tmp/lak-m502-*`. No device interaction, real-model run, quality
annotation or success-rate measurement was performed. Tests establish bounded
control flow and enforcement, not that the native model chooses useful repairs.
A revised proposal can still be semantically wrong while structurally valid.
Defaults within the opt-in model planner now permit recovery; the SDK's global
state-machine choice and declared-workflow behavior are unchanged. No new runtime
dependency, native framework import, installation request or network path was added.
