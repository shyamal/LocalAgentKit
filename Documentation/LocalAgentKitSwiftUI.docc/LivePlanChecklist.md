# Present the current plan

`AgentViewModel.planChecklist` exposes an event-derived ``PlanChecklist``. The demo shows
its rows in an expanded “Current plan” disclosure above the conversation. Each row has a
summary, symbol and text status, so color is not needed to understand progress.

The checklist resets on `AgentEvent.started` and replaces its rows when a new or revised
plan arrives. Unchanged steps retain their activity; changed or removed steps do not
inherit evidence from an old call. Dependencies remain available on each row's `step`.
The checklist is run-local and is not restored with conversation history.

## Correlate calls explicitly

Core's `ToolCall.planStepID` optionally names the matching `PlanStep.id`. Built-in declared
workflow, graph and model-driven planners populate it. Open-mode calls correlate with
the single open-plan row. Runtime execution IDs and repaired calls preserve the metadata.
Custom planners should supply this field; old call payloads still decode without it.

The checklist never guesses from tool names or parses call IDs. Unknown or duplicate
step identities cannot update an unrelated row. A changed execution call ID still
correlates through its explicit step metadata. Concurrent calls for distinct steps
update independently, and one returned call does not finish another active call.

## Interpret status as evidence

Preparing means a call was requested, before validation. Awaiting approval means the
permission event arrived. Running means execution started. Result received means a
correlated tool returned, including an empty result: the planner may retry or use an
alternative, so this does not assert successful completion of the step.

After successful run completion, an unobserved tool step says Not observed, not Skipped
or Complete. Non-tool steps say Run finished because the event stream does not report
individual reasoning-step transitions. Failure, refusal or cancellation stops unfinished
rows while retaining received results. Late events cannot reactivate a terminated run.

These are presentation states derived from existing events, not a new scheduler or audit
ledger. No tool arguments or document passages are displayed in the checklist.
