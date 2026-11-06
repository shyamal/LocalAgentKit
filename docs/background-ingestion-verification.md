# Background ingestion verification (M3-06)

Verified 2026-11-06 on a branch from merged M3-03/M3-02 main. PR #61 (M3-05)
was still open at task start; this implementation depends only on the existing
VectorStore protocol and does not include that PR's persistence code or tests.

Runtime's `IngestionJob` owns a detached utility-priority task. Sequential lazy
`DocumentIngestionSource` loaders produce Core Documents, which are chunked and
embedded one at a time. Only the configured positive batch of vectors waits for
insertion; every source flushes its last partial batch. Whole-document text and
chunks still occupy memory. No parallel provider calls or new protocol is added.

Core's `IngestionProgress` carries cumulative source/commit counts, current source,
job identity and running/completed/cancelled/failed lifecycle through the new
AgentEvent.ingestionProgress case. The separate single-consumer stream buffers
only its latest snapshot, so slow/absent observers do not grow memory unboundedly.
The terminal snapshot is yielded before stream finish. Existing exhaustive event
consumers compile; conversation UI ignores this separate host-job event.

Cancellation checks surround source/embedding awaits, precede insert and run after
successful commits and between sources. A late-cancelled successful store call
counts as committed; later work stops. Existing AgentErrors are preserved, unknown
errors become a generic retrieval failure and CancellationError becomes cancelled.
There is no rollback or retry. Cancelling a result waiter propagates to the shared
job; stopping event observation or dropping the handle does not cancel it.

Preflight rejects invalid batch/chunk settings or cancelled callers, and defaults
to NetworkPolicy.never, checking source/embedding network declarations. Hosts own
file scope, source declarations and VectorStore network suitability (the existing
store protocol has no network property). This does not bypass permission gates or
make arbitrary host closures trustworthy.

## Tests and checks

Thirteen new deterministic Runtime test functions cover:

- Bounded full/partial batches, metadata and cumulative completion across blank sources.
- Empty jobs, synchronous lazy loading off the main thread and live/coalesced snapshots.
- Cancellation after uncooperative loaders/embeddings, during a successful commit,
  by a result waiter, and through a thrown CancellationError.
- Partial success retained when a later source fails, and terminal embedding/store failures.
- Preflight limits, source/embedding network declarations, explicit allowance and cancelled callers.

Actor gates synchronize in-flight boundaries without timing-based assertions. The
result-waiter case uses a cancellable long sleep as a suspension point; cancellation
ends it immediately. A Tools integration function additionally generates a real PDF,
loads it lazily through DocumentExtractor and verifies actual mocked pipeline insertion.
All 14 functions need no model asset, personal file, network or physical device.

Warning-free strict build, all **683** branch Swift test functions, existing example
suites (4 custom-tool, 12 demo, 7 probe), **62** Python tests, strict formatting,
layering, DocC API/static routes (9,494 internal references) and generic iOS demo
build with signing disabled pass. Existing iOS metadata/orientation diagnostics remain.
Core/Runtime coverage is **98.95% (2828/2858)**, up 0.15 percentage points from
this branch's M3-03 base: Core 99.40% (823/828), Runtime 98.77% (2005/2030).

The initial network-denied run's Providers test process exited with signal 11.
Its crash report shows EXC_BAD_ACCESS in Core Data's mutable dictionary/derived
attribute trigger generation during SQLite setup. An unchanged network-denied
rerun passed every suite. The crash cause is not established; no test/assertion or
network-denial rule was disabled. The normal full suite and example suites passed.

## Limits

This is in-process cooperative background ingestion, not OS background entitlement,
a durable queue, restart recovery, admission/thermal policy or resource benchmark.
Native extraction/chunking or uncooperative providers cannot be forcibly interrupted.
The host must retain authorized file scope and explicitly own/cancel job lifetime.
An arbitrary store that throws after a partial write cannot communicate that commit
through the current protocol; progress acknowledges successful calls only. Completed
source counts reflect end-of-source checkpoints, not transactional corpus counts.
Re-running generates new chunk IDs, so cleanup/deduplication is host/store policy.

The existing direct RetrievalPipeline.ingest remains a single-insert API; no implicit
migration to jobs occurs. Model/permission behavior, prompt budgeting and runtime
dependencies are unchanged. No physical-device battery, large-corpus memory or
process-kill durability acceptance is claimed (M3-08/M6-05).

## Reproduce

```bash
swift build
swift test --filter 'IngestionJobTests|lazyPDFSource'
bash Scripts/check-coverage.sh
bash Scripts/check-offline-tests.sh
xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests Package.swift
bash Scripts/check-layering.sh
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
python3 Scripts/build-docs.py
python3 Scripts/check-docs.py .build/documentation/LocalAgentKit.doccarchive
```
