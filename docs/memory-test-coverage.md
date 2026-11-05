# Memory-layer verification (M2-13)

Measured 2026-11-05 with the full default suite, without a device or model assets.
The machine-readable line report is
[the coverage snapshot](verification/memory-coverage-2026-11-05.json).

## Scope and result

| Scope | Covered lines | Line coverage |
|---|---:|---:|
| Selected Core/Runtime memory files | 298/298 | 100.00% |
| Selected provider memory files | 286/299 | 95.65% |
| All Core + Runtime (M4 gate) | 2633/2666 | 98.76% |

The required gate remains **80% across Core + Runtime**, not a new provider gate.
Selected memory scope includes Core's Memory directory, Runtime ConversationMemory
and MemoryRetrieval, and both SwiftData store directories (including schema,
compatibility and migration helpers). Cross-cutting AgentRuntime, BudgetedModel
and ContextBudgeter remain in the full gate rather than being presented as purely
memory code. Testing mocks are exercised but are not part of these scoped totals.
The full gate is 0.15 percentage points below the preceding run: Core remains
99.17%, Runtime is 98.61%; this change adds two coverable Runtime lines.

Coverage unions hits for each source line across all default test binaries, as in
Scripts/check-coverage.sh. The JSON snapshot records per-file totals and uncovered
line numbers. These are line metrics, not proof of branch, race or failure-mode
exhaustiveness. Provider misses include encoding/error and rollback paths; tests
do not force real disk exhaustion or every native persistence failure.

## Behavioral matrix

| Contract | Regression suites |
|---|---|
| Task fact paths, empty markers, copies, events and reset | WorkingMemoryValueTests; RuntimeWorkingMemoryTests |
| Completed conversation turns, pruning, failures and history propagation | ConversationMemoryTests; AgentRuntimeMemoryTests; ConversationPersistenceTests |
| Checkpoint snapshots while local history changes/reset occurs | MemoryConcurrencyTests |
| Cancellation after a possible backend commit/load, lock release and typed cancellation mapping | MemoryConcurrencyTests |
| Stale summaries cannot overwrite newer turns/summaries; failed summaries preserve complete history | MemoryConcurrencyTests |
| Extremely large retention settings cannot overflow | MemoryConcurrencyTests |
| Semantic/episodic formats, category isolation, limits and invalid data | SemanticMemoryTests; EpisodicMemoryTests; SemanticMemoryStoreTests; EpisodicMemoryStoreTests |
| SwiftData persistence, updates/deletes, corruption, cancellation and migration compatibility | SwiftDataMemoryStoreTests; SwiftDataConversationStoreTests; MemoryMigrationTests; ConversationMigrationTests |
| Retrieval refresh, fitting with RAG, network policy, failures and injection denial | MemoryRetrievalTests |
| Reopened conversation + semantic + episodic stores, task facts and actual fitted model input together | MemoryLayerIntegrationTests |

## Added evidence

Eight new test functions add deterministic concurrency barriers and an integration
path through real temporary SQLite files. Checkpoint cancellation tests deliberately
model a backend that can commit despite cancellation; the caller reports cancellation,
keeps local history and can checkpoint again. A checkpoint keeps the snapshot taken
before its backend await, even if the local history changes. A later explicit save
is required to persist the changed/reset history.

The integration test reopens separate knowledge/checkpoint files, restores prior
conversation, retrieves durable preference/episode records, observes a task-only
fact and verifies all reach one model request within its measured token budget.
Only completed user/assistant text is checkpointed; the fixture's unique task-only
marker is absent from both persisted conversation and the knowledge store. Completed
answers can naturally quote facts; this behavior is not output redaction. This verifies the seams together,
not just each DTO/store in isolation.

Code review found an unchecked share × retention-multiple product in
ConversationMemory. The product now saturates at Int.max on overflow instead of
trapping or accidentally triggering pruning. Extreme-setting tests retain ordinary
completed turns, while the normal budgeter still fits every model call separately.

Run the checks from the repository root:

```bash
swift build
bash Scripts/check-coverage.sh
bash Scripts/check-offline-tests.sh
swift test --filter 'MemoryConcurrencyTests|MemoryLayerIntegrationTests'
swift test --sanitize=thread --filter MemoryConcurrencyTests
```

Capture coverage before changing instrumentation for the sanitizer run. Per-file
figures can be reproduced by exporting LCOV with llvm-cov for the same test binaries
and default.profdata used by check-coverage.sh, selecting the source paths above and
unioning each source/line's hit count across binaries.

## Limits

The tests use mocks for generation and synthetic data in temporary stores. Reopening
files is not a physical app restart, UI resume validation, an outside-developer
trial or an OS-beta measurement. Concurrent fake backends establish caller behavior;
they do not prove that every SwiftData commit can be interrupted or every filesystem
failure is atomic. Demo resume remains M2-14. The seven new concurrency test
functions also pass under Thread Sanitizer; this sanitized run does not replace
the full-suite coverage measurement.

Existing deferred Milestone 1 gates remain open, and this result does not declare the milestone or memory subsystem
exhaustively verified.
