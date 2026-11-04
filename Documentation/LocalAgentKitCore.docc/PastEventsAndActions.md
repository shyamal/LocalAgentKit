# Remember past events and actions

`EpisodicMemory` records an event or action through the same `MemoryStore` used for
ordinary and semantic memories. The host explicitly chooses what to retain; the
runtime does not automatically record tool calls or infer that an action succeeded.
An episode is remembered data, not authority to execute or repeat an action.

## Record and find an episode

```swift
import LocalAgentKitCore
import LocalAgentKitProviders

let store = try SwiftDataMemoryStore(storage: .file(memoryURL))
// Call after the app has confirmed the operation actually completed.
let savedNote = EpisodicMemory(
  kind: .action, content: "Saved the Budget review preparation checklist",
  occurredAt: completionDate, metadata: ["source": "note-save"])
try await store.save(savedNote)
let actions = try await store.searchEpisodic(text: "Budget", kind: .action, limit: 5)
try await store.delete(id: savedNote.id)
```

Use `.event` for something that happened, such as a completed meeting. `occurredAt`
is mandatory; `createdAt` defaults to the recording time. Both dates are preserved.
Reuse the same UUID to correct an episode, including its description, kind, dates
and app metadata. Different IDs remain distinct even with identical text.
A file-backed SwiftData store preserves episodes across reopening the same file;
`.inMemory` is transient.

The app determines truth, success and consent before saving. Saving an `.action`
record does not call a tool, authorize a write, or replay an operation. Failed or
denied operations are not automatically converted to successful action memories.

## Search and ordering

`searchEpisodic` applies exact category and optional event/action metadata filters
before the limit, so unrelated ordinary/semantic rows cannot crowd out episodes.
Text matching and ordering follow the store. In SwiftData that means localized
content substring matching and newest **recording** date first, with UUID-string
ascending for ties. It does not order by occurrence date or support date-range
queries. The mock preserves its insertion ordering. Non-positive limits return no
results. Use explicit deletion by UUID to forget an episode; resetting task or
conversation memory does not remove it.

## Versioned encoding

No SwiftData schema changes are needed. The existing `Memory` fields hold UUID,
content, creation date and app metadata. Four exact metadata keys are reserved:

| Key | Version-one value |
|---|---|
| `localagentkit.memory.category` | `episodic` |
| `localagentkit.episodic.kind` | `event` or `action` |
| `localagentkit.episodic.version` | `1` |
| `localagentkit.episodic.occurredAt` | Finite floating-point seconds since 2001-01-01 00:00:00 UTC |

The occurrence timestamp uses Foundation's reference date to preserve `Date`'s
floating-point precision. It is an internal storage representation, independent
of locale or display formatting. App metadata may not override these keys.
Blank descriptions, non-finite dates, malformed/missing occurrence timestamps and
unknown categories, versions or kinds fail with `AgentError.memoryFailure`.
Invalid matched rows are reported rather than silently skipped. Existing store
failures and cancellation propagate through the typed helpers.

Saving/searching does not change runtime state or insert episodes into model
prompts. Budgeted retrieval remains M2-07. Episodes share the existing small-store
metadata scan behavior described in the provider's local-memory guide.
