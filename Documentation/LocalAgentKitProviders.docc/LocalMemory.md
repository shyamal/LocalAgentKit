# Store local memories

Use `SwiftDataMemoryStore` through Core's `MemoryStore` protocol. The provider
owns its SwiftData model context on a serial model executor; callers exchange
only Sendable Core values. CloudKit is disabled. No model assets are required.

## Choose storage explicitly

```swift
import LocalAgentKitCore
import LocalAgentKitProviders

let store = try SwiftDataMemoryStore(storage: .inMemory)
let memory = Memory(content: "Prepare the budget review", metadata: ["project": "demo"])
try await store.save(memory)
let matches = try await store.search(MemoryQuery(text: "budget", limit: 5))
try await store.delete(id: memory.id)
```

`.inMemory` is transient and useful for tests/previews. For durability, choose
`.file(yourAppOwnedFileURL)` with a URL in the app's storage directory. The parent
directory is created when necessary. Reopening that URL reads the same records.
Non-file URLs and initialization failures throw `AgentError.memoryFailure`.

The schema is `MemorySchemaV1` (1.0.0), internal to Providers. It preserves UUID,
content, creation date and app-defined string metadata encoded as JSON data.
Migration policy remains M2-08; this version does not claim future schema upgrades
will migrate automatically.

## Operation behavior

- Saving an existing ID replaces its content, creation date and metadata. Each
  mutation explicitly commits; autosave is disabled.
- Search matches localized case/diacritic-insensitive substrings in content.
  Metadata is not searched. Empty text matches all memories. Results are newest
  first, with UUID-string ascending for equal timestamps. Non-positive limits
  return an empty array.
- This implementation materializes matching rows before sorting and limiting;
  it is intended for small local stores. It is not semantic/vector search.
- Deleting an absent ID succeeds without a write.
- Corrupt metadata in a returned record is a typed failure, not silently replaced
  with an empty dictionary. Initialization and operation failures map to
  `AgentError.memoryFailure`.
- Cancellation is checked before database work and before committing mutations.
  Failed/cancelled mutations roll back pending context changes. A synchronous
  SwiftData save already in progress cannot be interrupted.

Copies of the store share its private model actor. Use one store instance per
file in an app for serialized access; cross-process coordination and simultaneous
independent writers are not part of this contract.

## Integration status

Supplying `AgentConfiguration.memory` does not yet activate retrieval or persisted
chat history. Explicit conversation restore/checkpoint operations are available through
`ConversationMemory` and `SwiftDataConversationStore`, using a separate file.
Automatic context retrieval and demo resume remain M2-07 and M2-14. Runtime task working memory is separate from this durable store. Semantic and
episodic category behavior remains later work; metadata keys are app-defined. The existing `MockMemoryStore`
implements the same save/search/delete seam for unit tests, with its own matching
and ordering behavior.
