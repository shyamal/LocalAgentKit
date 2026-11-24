# Schedule a task graph

Use ``TaskGraphPlanner`` for an application-declared directed acyclic graph. Pass it as
an `AgentRuntime` planner. Existing planners and ordered workflows keep their behavior.

Wrap each `WorkflowStep` in a ``TaskNode``. Its `dependsOn` set names prerequisite node
IDs. Result bindings and guard references infer additional edges using binding aliases.
Model argument hints do not infer dependencies; declare those edges explicitly.

The planner validates identities, tools, argument sources, references and cycles before
execution. It publishes topologically ordered plan steps with their dependency IDs.
A final response automatically waits for all tool nodes. Skipped nodes release their
dependents, but do not manufacture missing bound values.

Ready nodes run in stable declaration order within topological layers. Independent
parallel-safe steps can form batches of at most four calls. Set `retries: 0` explicitly
on batch candidates: the workflow default permits retries, which keeps a step serial.
Steps with alternatives, skip-on-failure policies or recovery in progress also stay serial.
Arguments are resolved serially through the existing budgeted model path before dispatch.
Bound facts must match the destination schema; the model cannot replace incompatible facts.

Batches join before downstream scheduling. This is bounded layered scheduling, not a
continuously pipelined scheduler. Existing run limits, permissions, cancellation and
batch failure semantics still apply; see <doc:ParallelToolExecution>. Batches provide
no rollback and this feature makes no measured speed or energy claim.
