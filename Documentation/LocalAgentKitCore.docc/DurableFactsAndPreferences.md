# Save durable facts and preferences

`SemanticMemory` represents an explicitly retained fact or user preference. It uses
`MemoryStore` save/search/delete operations, so the local SwiftData store and the
mock support the same API. “Semantic” describes the category of retained knowledge;
search still follows the store's text matching rules, not vector similarity.

## Save, search, update and forget

```swift
import LocalAgentKitCore
import LocalAgentKitProviders

// Use an app-owned file URL for persistence; .inMemory is transient.
let store = try SwiftDataMemoryStore(storage: .file(memoryURL))
var preference = SemanticMemory(
  kind: .preference, content: "Use metric units", metadata: ["source": "settings"])
try await store.save(preference)
let preferences = try await store.searchSemantic(text: "", kind: .preference, limit: 5)
preference.content = "Use imperial units"
try await store.save(preference) // Same ID replaces the previous statement.
try await store.delete(id: preference.id)
```

Use `.fact` for a durable statement such as “The office is in Paris.” UUID identity,
creation time and app metadata round-trip unchanged. Different IDs remain distinct,
even if their text matches. The app decides which statements are true, whether one
supersedes another, and when to obtain consent. This host API does not install a
memory-writing tool, infer facts from conversations, or grant tool permission.

## Storage and search contract

`SemanticMemory.memory()` encodes an ordinary `Memory` with three reserved metadata
keys: `localagentkit.memory.category` (`semantic`), `localagentkit.semantic.kind`
(`fact` or `preference`) and `localagentkit.semantic.version` (`1`). App metadata
cannot use those exact keys. Decoding rejects other categories, unknown versions
or kinds, and blank statements with `AgentError.memoryFailure`.

`MemoryQuery.metadata` requires exact, case-sensitive key/value matches, combined
with AND **before** applying the limit. An empty dictionary keeps the previous
unrestricted behavior. Custom `MemoryStore` implementations must honor this
contract; filtering a limited result afterward can hide valid older facts.
`searchSemantic` restricts the category and optional kind using these constraints.
It preserves provider ordering and rejects invalid matching records instead of
silently discarding them. Non-positive limits return an empty array.

The SwiftData implementation stores this envelope in the existing metadata field;
no SwiftData schema change is needed. Exact metadata filtering decodes candidate
rows in order until the requested count is found. Corrupt metadata encountered in
that scan throws a typed memory error, including corruption in a candidate that
might otherwise have been excluded. This implementation is intended for small
local stores. Reopen the same file URL to retrieve saved facts after restart.

## Context integration

Saving or searching facts does not change runtime task state, emit runtime events,
or insert anything into model prompts. Budgeted automatic retrieval remains M2-07.
Use explicit saves after the app's own approval flow. Resetting conversation or
working memory does not delete durable facts; delete their IDs when requested.
