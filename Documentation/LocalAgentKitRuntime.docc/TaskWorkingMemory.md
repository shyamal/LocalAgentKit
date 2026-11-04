# Inspect task working memory

Working memory holds ephemeral facts for one task. `AgentContext.workingMemory`
is the storage behind workflow bindings; it is not another copy of the planner's
bindings or a persistent memory database. Core's `WorkingMemory` value holds
JSON values, insertion order and explicit empty-result markers.

## Use task facts in a planner

```swift
context.workingMemory.set(.string("Budget review"), forKey: "meeting")
let meeting = context.value(for: "meeting")
```

Workflow tool steps bind their structured result (or text) into this same memory.
Open planning records successful observations under their tool-call IDs, retaining
repeated calls separately. Failed or denied calls do not create facts.
Open-mode prompts retain the observation text, including units and explanations,
while memory snapshots retain the structured value. Custom task facts are also
included without duplicating the observed tool-call bindings.
Later steps can reference nested paths such as `matches.0.title`. A tool may mark
a root empty even if its text explains why nothing was found. Zero and false are
valid facts, not empty values. Replacing a root preserves its position; removing
and reinserting it places it at the end.

Custom planner changes become observable when its callback returns or throws.
Working memory is data, not authority: a value named `approved` cannot authorize
an execution. Tool schemas, permission gates and execution limits still apply.

## Observe a running or finished task

```swift
let facts = await runtime.workingMemory()
let value = facts.value(for: "meeting")
```

This is a value snapshot. Editing the returned copy does not change the runtime
or planner. The runtime publishes `AgentEvent.workingMemoryUpdated` when facts
change, and publishes an empty snapshot when each run begins. Existing event
consumers with exhaustive switches must handle that new case. `AgentViewModel`
exposes the latest snapshot through its `workingMemory` property.

Before the first run, task memory is empty. A new run always starts empty. The
last task's facts remain inspectable after success, error or cancellation until
the next run. Observing a terminal snapshot does not resume or replay a task.

## Storage and context boundaries

Task facts do not call `MemoryStore`, populate conversation history, or survive
app restart. ConversationMemory supports explicit persisted checkpoints (M2-04); working
facts are excluded from them. Configuring `AgentConfiguration.memory` enables
separate budgeted retrieval of durable text/semantic/episodic records (M2-07).
Demo resume wiring remains M2-14. Category behavior uses the typed encoding, not
an arbitrary app-defined metadata key.

Built-in planner prompts render relevant binding facts through the existing
bounded fact renderer and context budgeter. Keeping a value in working memory
does not guarantee its entire contents fit in every model request. Hosts should
avoid retaining sensitive snapshots longer than needed; snapshots include tool
results and may contain user data.
