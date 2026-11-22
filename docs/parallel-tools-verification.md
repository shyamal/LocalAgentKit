# Explicit parallel tool batches (M5-04)

Implemented and verified on 2026-11-22. Custom planners can emit independent ready
calls through PlannerDecision.callTools. The built-in state-machine/model-driven
planners remain ordered; automatic dependency discovery and scheduling stay M5-05.
This is execution support, not a native throughput or energy measurement.

## Execution contract

Runtime scopes each invocation to a unique execution ID, reserves the entire batch
against the tool-call budget, and checks every call against existing loop protection.
A batch consumes one planner iteration. Empty batches fail. Batch arguments are
concrete: batch failures end the run without model argument repair or planner
recovery; the existing single-call path retains its repair/recovery behavior.

ToolExecutor resolves each implementation once and captures its contract. All
schemas validate before any permission request, and all required permissions are
obtained sequentially before execution. A denied member prevents any prefix from
executing. Work uses those same resolved implementations and contracts, avoiding a
second dynamic-source lookup between validation/authorization and execution.

Every tool must declare isParallelSafe for overlap; one unsafe member serializes
the whole batch. Safe batches run at most four calls at once, admitting queued work
as slots finish. Remaining run time is checked before each start, including
noncancellable tools; existing noncancellable work may still finish after expiry.
Cancellable work uses the existing deadline wrapper. Failure cancels siblings and
prevents subsequent queued starts. Successful results are returned/observed in input
order; per-call events retain actual execution order and correlated IDs.

Batches are not transactions. Work already completed cannot be rolled back when a
peer fails. Completed-member events can appear before a batch error, but planner
facts are observed only after a successful join. Cancellation suppresses late
success events/facts. Confirmed results returned to the executor are audited before
that suppression, including a noncancellable operation completing after cancel.
Audit remains completed-result-based, not a transaction journal: an operation
abandoned by the existing deadline wrapper may have an unknown outcome if its
implementation ignores cancellation. This change does not guarantee native
termination or reconstruct such outcomes.

A tool-call instrumentation span covers the complete batch. AgentViewModel now
exposes activeTools; activeTool remains the most recently started remaining call.
The demo displays all active calls, and terminal events clear concurrent state.
Custom drivers switching exhaustively over PlannerDecision must handle callTools.
No protocol or runtime dependency was added. Shared resources across independent
runtimes remain subject to provider/host coordination.

## Verification

Sixteen new batch functions and one UI function bring the full suite to
**864 registered functions**. Actor gates prove overlap and a four-call maximum,
including delayed admission of a fifth call, without a wall-clock speed assertion.
Tests cover unsafe serialization, whole-batch schema/identity/source validation,
serialized human approvals, no work before denial, source snapshot consistency,
ordered results, unique runtime IDs, loop/tool-call budgets, sibling cancellation,
runtime cancellation, partial-failure fact isolation, per-call deadlines,
noncancellable queued-work expiry and confirmed-result auditing after cancellation.
The UI regression releases one member while another remains active and verifies
its activity remains visible through completion.

The runtime cancellation test waits for cooperative fixture cleanup separately:
the existing deadline wrapper can return before underlying work finishes unwinding.
The queued noncancellable regression uses an injected budget transition rather
than a timing guess. Existing single-call executor, permission, audit, repair and
UI tests remain passing; no test was removed or disabled.

Final checks:

- Full/default and network-denied SDK suites pass: 864 registered functions.
- Focused Thread Sanitizer run passes all 16 batch and 19 AgentViewModel functions,
  with no sanitizer warnings. This is focused concurrency coverage, not a claim
  that the entire SDK suite was run under the sanitizer in this task.
- Core/Runtime coverage **98.94% (3628/3667)**, up 0.03 percentage points from M5-03.
  Core **99.80% (982/984)**, up 0.10; Runtime **98.62% (2646/2683)**, up 0.01.
- Demo 45, EmbeddingProbe seven and resource probe six functions pass; all
  80 Python tests pass.
- Strict changed-file formatting, layering and diff checks pass.
- Strict DocC build/routes pass: six modules, 11,006 internal topic references.
- Generic iOS demo build succeeds with existing AppIntents/orientation diagnostics.

Logs use `/tmp/lak-m504-*`; final full/offline evidence is
`/tmp/lak-m504-complete-coverage.log` and `/tmp/lak-m504-complete-offline.log`.
Focused sanitizer evidence is `/tmp/lak-m504-tsan-complete.log`. No native model
run, real-device tool execution, latency benchmark or energy measurement was
performed. No traffic-capture claim is made. M5-03's historical no-go decision/default is unchanged.
