# Parallel tool execution

Submit explicitly independent ready calls while preserving validation, permission and run limits.

## Emit a batch from a custom planner

Return `PlannerDecision.callTools` from your `AgentPlanner.next` implementation:

```swift
return .callTools([
  ToolCall(
    id: "sum", name: "calculate",
    arguments: ToolArguments(["expression": .string("2 + 2")])),
  ToolCall(
    id: "product", name: "calculate",
    arguments: ToolArguments(["expression": .string("3 * 7")])),
])
```

These are concrete arguments ready for execution, with no dependence between the
calls. Emit the batch once. Your `observe` handler records results in the public
`context.workingMemory`; subsequent `next` decisions can answer or select further
work. The runtime observes successful batch results in submission order, even
when calls finish in a different order. `call.id` is scoped to a unique runtime
execution ID; correlate events/results using that observed ID, not the original
planner ID alone.

The built-in state-machine and model-driven planners retain their ordered workflow
behavior. This API does not infer dependencies or ask the model for parallel plans.
For opt-in declared dependencies and ready-work scheduling, see <doc:TaskGraphs>. Custom drivers
with exhaustive switches over PlannerDecision must handle the new case.

## Admission before execution

The runtime reserves every member against `maxToolCalls` before executing any of
them, and checks the unchanged loop detector for all calls. A batch consumes one
planner iteration; it cannot bypass the separate tool-call limit. Empty runtime
batches are rejected. Batch failure ends the run without model argument repair or
planner recovery; the existing single-call path retains bounded repair/recovery.

ToolExecutor resolves each implementation once, captures its descriptor and validates
all argument schemas. It then obtains all required human confirmations serially,
with no work executing while another confirmation remains unresolved. A denied
member prevents the whole batch from starting. The normal runtime permission broker
and audit policy remain active; there is no blanket batch authorization.

If every resolved tool declares `isParallelSafe`, at most four execute at once.
Additional calls wait for a slot. If any member is unsafe, the entire batch executes
serially. The same resolved implementation/contract is used after admission, so a
dynamic ToolSource cannot swap metadata between validation and execution. A tool's
flag remains the host's declaration of safety; shared resources across independent
runtimes still need appropriate provider/host coordination.

## Failure, cancellation and visibility

The first observed execution failure cancels sibling tasks and prevents further
queued work from starting. Cancellation and run deadlines remain typed errors.
Each tool checks remaining time before starting, including noncancellable tools.
Running noncancellable work can delay cleanup until it finishes. Cancellable work
uses the existing deadline wrapper; an implementation that ignores cancellation
can outlive that wrapper. Cancellation is not a guarantee of immediate native
termination.

Batches are not transactions. Completed operations remain completed if another
member fails. Per-tool events can already show completed work; planner observations
are applied only after a successful batch join. No batch facts or successful final
response are fabricated after failure/cancellation. Confirmed results returned to the executor are audited even if cancellation
suppresses their late success events. This is completed-result auditing, not a
transaction journal; an abandoned implementation that ignores cancellation can
leave an unknown outcome.

Per-call requested, permission, started, completed and observation events retain
unique IDs and actual execution order. The `.toolCall` instrumentation interval
covers the whole batch. `AgentViewModel.activeTools` tracks all started calls;
`activeTool` remains a compatibility view of the most recently started remaining
call. The reference demo displays every active call separately.

Tests use actor gates to prove overlap and the four-call bound without timing-based
speed assertions. They cover serial fallback, whole-batch admission, permissions,
correlation, deterministic result order, cancellation, partial failure, deadlines,
auditing and multi-tool UI state. This establishes execution semantics, not a
native latency or energy improvement.
