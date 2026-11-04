# Conversation checkpoint verification — 2026-11-04

M2-04 adds explicit completed-history checkpoints, not automatic app UI resume.
Verified on macOS 26.6.2 with Xcode 27.2 (27B52), using fixture text and scripted
models. No physical device, model asset or cloud service was required.

## Automated checks

Fifteen new test functions (including parameterized cases) cover:

- Core validation of complete turns, optional summaries and rejected tool/partial traffic.
- Mock/SwiftData store contract: session isolation, replacement and deletion.
- Disk reopening, Unicode/newlines, invalid replacement preservation, cancellation,
  corrupt JSON, unknown formats/roles and checkpoint identity mismatches.
- Restored context reaching a fresh runtime, explicit checkpoint timing, missing
  sessions, durable empty resets, typed backend errors and default network rejection.
- Failed saves retaining local/previous committed history, overlapping checkpoint
  rejection and reset during delayed summary generation.

Reproduce the focused suites with:

```bash
swift test --filter 'ConversationSnapshotTests|ConversationPersistenceTests|SwiftDataConversationStoreTests'
```

Warning-free package build, full default/offline suites, strict formatting/layering,
31 Python tests, strict DocC and 8,117 internal topic route checks passed.
Core/Runtime coverage: 98.47% (2382/2419).

## Separate process check

A temporary Swift executable used the public APIs and an isolated local SwiftData
file. One invocation ran a scripted answer and checkpointed the completed pair,
then exited. A second invocation opened the same file/UUID, restored two messages,
created another runtime and asserted its model request contained the earlier answer.

```text
WRITE PASS: completed conversation checkpoint committed
RESTORE PASS: new process and runtime used both completed text messages
```

Probe source/build outputs were under /tmp/lak-conversation-restart-probe; write
and read logs were kept locally under /tmp/lak-conversation-restart-{write,read}.log.
No user conversation or device note content was used or committed as a fixture.
This verifies process-restart durability on the Mac; it is not an iPhone UI resume
claim. Automatic demo resume, unified durable retrieval and schema migrations
remain M2-14, M2-07 and M2-08 respectively.
