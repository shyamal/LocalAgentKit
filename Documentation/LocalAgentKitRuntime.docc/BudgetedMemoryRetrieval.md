# Retrieve stored memories within the context budget

Set `AgentConfiguration.memory` to search persistent memories once per run, before
planning begins. Retrieved text is supplied to every model call through the same
`BudgetedModel` and retrieval allocation used for RAG. It is never appended after
context fitting. Task working memory and conversation history remain separate.

## Choose the search policy

```swift
let configuration = AgentConfiguration(
  model: model,
  memory: store,
  memoryRetrieval: MemoryRetrievalConfiguration(
    query: .recent, limit: 5,
    metadata: ["localagentkit.memory.category": "semantic"]))
let runtime = try AgentRuntime(configuration: configuration, tools: tools)
let response = try await runtime.run("Help me prepare")
```

The default `.goal` query passes the **entire current goal** as text, with a limit
of five and no metadata constraints. It does not extract keywords, rewrite the
query or perform embedding similarity. SwiftData matches content substrings, so a
long natural-language question may not match a shorter stored fact. Use `.recent`
(empty query text) for general preferences/facts independent of the goal wording,
or add exact metadata constraints to scope retrieval. SwiftData returns newest
recordings first; other stores keep their own matching/order contract.

No store means no search. A zero limit disables retrieval; negative limits fail
runtime construction. Supplying a store now activates reads where it was previously
reserved configuration. Custom `MemoryStore` implementations must honor exact
metadata constraints before applying limits and declare `requiresNetwork` honestly.
The local-only default preserves existing conformances. A network-requiring store
is rejected during runtime construction under `.never`, even with a zero limit;
`.allowed` explicitly permits declared network components.

## What enters a prompt

Ordinary text, semantic facts/preferences and episodic events/actions are labelled
as stored reference data. Typed category records are decoded before use; malformed
or unsupported records fail retrieval rather than being presented as valid facts.
Episodes include occurrence time. App metadata is used for filtering and decoding,
not copied wholesale into the prompt. No retrieved record is automatically saved,
modified or treated as permission to execute a tool.

RAG passages come first, followed by memories in provider order, within the existing
retrieval section (currently headed “Relevant documents”). They share
`ContextBudgetConfiguration.retrievalShare`; memory has no separate guaranteed
allocation. The budgeter can drop lower-ranked passages, including whole memories,
to fit the actual token window and response reserve. Even a selected memory may
therefore be absent from a particular fitted call. Large memories are not guaranteed
to be summarized. Each new run searches again and retains no prior retrieval cache.

Conversation transcripts are supplied through `ConversationMemory`, including its
explicit restore/checkpoint APIs. They are not mixed into text-store search, and
runtime task facts continue to use the planner's bounded facts renderer. The demo
still needs separate persistence/resume wiring (M2-14).

## Failure and observation

- `AgentEvent.memoriesRetrieved(count:)` reports selected records before fitting,
  including zero results. It contains no memory text and is not an inclusion receipt.
- `AgentEvent.memoryRetrievalFailed` reports a typed best-effort search/decoding
  failure. The run continues without persistent passages; RAG remains available.
  Backend error messages may contain sensitive diagnostics, so handle them like
  other runtime errors. The default SwiftUI view model does not display these events.
- Cancellation and the active run deadline remain terminal. A store that ignores
  cancellation is abandoned by the runtime's existing deadline mechanism; its
  underlying task may remain alive until the provider returns.
- Runtime instrumentation records persistent retrieval under `.retrieval`. No
  memory writes or automatic fact/episode extraction are added.

Permission checks remain validate arguments → permission gate → execute → observe.
Reference-data labels do not make model output trustworthy; a writing call induced
by stored text still requires human approval.
