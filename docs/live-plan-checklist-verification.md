# M5-07 live plan checklist verification

Verified 2026-11-24 with synthetic tool/model fixtures. The iPhone interface was built,
but manual physical-device visual acceptance was not performed.

## Behavior

AgentViewModel exposes run-local PlanChecklist rows. The demo renders the latest plan in
an expanded disclosure with summary, icon and text status. Tool arguments, document
contents and raw dependency IDs are not added to the displayed checklist.

Optional ToolCall.planStepID correlates tool events with declared steps. Built-in workflow,
graph and model-driven calls populate it; open-mode calls use the open-plan row. Runtime
UUID scoping, parallel batch construction and argument-repair retries preserve metadata.
Old encoded calls decode with nil metadata. Custom planners may opt in explicitly.

Revisions preserve only unchanged-step evidence. Duplicate or unknown identities cannot
mark another step. Terminal events freeze the presentation until a new run resets it.
Results, including empty results, say Result received; the display does not invent step
success or infer skips from absent events. Non-tool rows say Run finished only when the
run completes. Unobserved tool rows remain unchecked. The checklist is not persisted.

## Checks

- Full and offline suites: 892 registered functions passed (eight new functions).
- Seven checklist functions exercise same-tool distinct steps, retries, permissions,
  concurrent calls, plan revisions, missing/duplicate metadata, terminal states, late
  events, run reset and real runtime/view-model integration.
- One Core test checks old-call decoding and new-call round-trip encoding.
- Existing graph fan-in integration now asserts metadata survives parallel dispatch.
- Thread Sanitizer: 34 checklist/view-model/graph functions passed without reported races.
- DocC build and static routes passed: six modules, 10,529 internal references.
- Demo: 45 tests passed; generic iOS build succeeded with signing disabled.
- Warning-free Swift build, strict changed-file formatting, layering and whitespace checks passed.
- Core: 99.80% (993/995); Runtime: 98.56% (2945/2988).
- Combined coverage: 98.87% (3938/3983), down 0.02 percentage points from M5-06;
  Core unchanged, Runtime down 0.03 points.

## Limits

This is a presentation projection, not an execution ledger. Existing events do not name
individual reasoning transitions or skipped nodes. The checklist deliberately avoids
claiming either. Applications with custom planners must provide explicit metadata for
per-step tool progress. Source-level exhaustive switches are unaffected: no AgentEvent
case is added. Permissions, planning, cancellation and execution policy remain unchanged.
