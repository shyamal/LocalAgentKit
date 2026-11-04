# Persist completed conversations

`ConversationMemory` is in-memory by default. Restore and checkpoint operations
support app restarts through Core's `ConversationStore` protocol and Providers'
`SwiftDataConversationStore`. No model assets are needed to persist data.

## Restore before creating the runtime

The app supplies a stable `conversationID` (a UUID retained across launches) and
an app-owned file URL. Use a dedicated conversation file, separate from the
`SwiftDataMemoryStore` database or any other SwiftData schema.

Given those values and the app's configured model/tools:

```swift
import LocalAgentKitCore
import LocalAgentKitProviders
import LocalAgentKitRuntime

let checkpoints = try SwiftDataConversationStore(storage: .file(fileURL))
let memory = try await ConversationMemory.restore(
  from: checkpoints, conversationID: conversationID)
let runtime = try AgentRuntime(
  configuration: AgentConfiguration(model: model), tools: tools, memory: memory)
let response = try await runtime.run(goal)
try await memory.checkpoint(to: checkpoints, conversationID: conversationID)
```

Await `runtime.run` before checkpointing. Its `.completed` event can arrive before
history recording finishes, so checkpointing directly from that event can save
an older history. This task adds explicit persistence, not automatic saving on
every event. Automatic demo resume wiring remains M2-14.

A missing identity starts empty. Corrupt data, unknown checkpoint formats and
identity mismatches throw typed memory failures; they are not treated as a new
conversation. Restore validates complete user/assistant text pairs, with an
optional leading compacted summary, and applies normal retention pruning.
Tool calls/results and incomplete turns cannot be checkpointed.

## Checkpoint and reset behavior

Only completed agent turns are recorded by the runtime. Failed, refused and
cancelled runs do not append partial output. Checkpointing replaces one identity's
whole history atomically; it never deletes old rows before writing their replacement.
A failed save preserves local history and the backend's previous committed value.
Retry storage persistence separately from agent execution to avoid repeating tools.

The app should await each checkpoint. A second checkpoint on the same memory
instance is rejected while the first is in flight. Use one writer per conversation;
separate instances writing the same identity do not merge histories and may replace
each other's snapshots. Different identities remain isolated.

`reset()` clears local history only. Checkpoint that empty history to durably reset
the session, or call the store's `delete(conversationID:)` to remove its checkpoint.
Keep the app's identity lifecycle consistent with that deletion. Delayed summaries
cannot reinstall old messages after a local reset.

## Policy and storage

Restore/checkpoint default to `.never` network policy and reject a store declaring
`requiresNetwork` before I/O. An app may explicitly pass `.allowed` for its own
backend. These host-invoked operations have their own policy; they are not implicit
agent model/tool work. The supplied SwiftData store is local and disables CloudKit.

The provider uses an internal versioned SwiftData schema and version-1 JSON
checkpoint payload. Schema migration policy remains M2-08; unsupported payload
versions fail closed. The SDK does not bundle model sessions or execution state
into checkpoints. Working memory still resets per run.

Cancellation is checked before persistence work and after awaited operations.
A synchronous commit already in progress may complete despite cancellation.
Explicit restore/checkpoint failures throw to the host; they do not reclassify a
completed tool action as failed or automatically trigger another agent run.
