# M5-05 task graph verification

Verified 2026-11-24 with synthetic tools and mocked model responses. No physical-device
performance or model-quality claim is made.

The opt-in TaskGraphPlanner validates application-declared DAGs before work. Explicit
node edges and inferred binding/guard edges determine readiness. A final response waits
for all tool nodes. Stable ready batches are capped at four; unsafe and recovery-bearing
nodes stay serial. Arguments remain budgeted and incompatible bound facts fail rather
than being replaced by generated values. Existing planners remain unchanged.

Eight graph test functions (including sixteen invalid-graph cases) cover fan-in, reordered
declarations, inferred edges, width limits, guard skips, retry/alternative recovery,
permission denial, explicit model-argument dependencies and bound-fact type rejection.

Validation passed:

- Full coverage suite: 872 registered test functions; offline suite passed.
- Core: 99.80% (983/985 lines); Runtime: 98.51% (2905/2949).
- Combined coverage: 98.83% (3888/3934), down 0.11 percentage points from M5-04.
- Thread Sanitizer: 24 graph and parallel-tool functions, no reported races.
- Strict formatting, layering and whitespace checks.
- DocC build and static routes: six modules and 10,323 internal references.
- Generic iOS demo build with signing disabled.

Scheduling joins a selected batch before reconsidering dependents. It does not pipeline
individual downstream nodes while another batch member is still running. Batch failures
remain terminal; permission, cancellation, deadlines and run budgets use the existing
executor semantics. This is not transactional execution and cannot forcibly stop
noncooperative tool work.
