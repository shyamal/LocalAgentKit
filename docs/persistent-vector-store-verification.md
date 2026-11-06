# Persistent vector store verification (M3-05)

Verified 2026-11-06. `FileVectorStore` in Providers implements the existing Core
`VectorStore` protocol with version-1 JSON snapshots. A Swift 6 complete-concurrency
scratch probe against the installed SDK verified JSON encode/decode, bounded
FileHandle reads and atomic Data writes before implementation. Only Foundation
is required; no Core/Runtime behavior, new protocol, runtime event, dependency or
permission tier is added. The existing mock remains the protocol test counterpart.

## Behavior

The host configures an explicit local URL, embedding-space identifier, dimension
and positive byte budget (32 MiB default). Missing files start empty; corrupt,
nonregular, unreadable, oversized, duplicate-ID, wrong-version or mismatched-space
snapshots fail closed. Space identity is host-declared: equal dimensions do not
establish compatible model/tokenizer/pooling/fallback semantics.

Inserts validate all vectors and upsert by ID, last batch occurrence winning.
Removals persist; absent IDs and empty inserts do not rewrite storage. Mutations
write the whole candidate snapshot atomically before updating the cache; failures
retain the cache. Only one actor may own a file. Independent instances/processes
and external edits are not coordinated, and no power-loss/fsync guarantee is made.

Exact cosine search uses Double intermediates and Float scores, with UUID-ascending
ties. Finite nonzero vectors must match configured dimensions. No thresholds, ANN
index, text deduplication or automatic source-document replacement is introduced.

## Tests

Fifteen generated temporary-file test functions cover:

- Missing-file reads, lazy creation and fresh-instance round trips retaining all fields.
- Duplicate-ID replacement and last batch occurrence winning.
- Known cosine scores, deterministic ties and nonpositive result limits.
- Greatest-magnitude/subnormal finite vectors without arithmetic overflow.
- Invalid query/batch vectors and whole-batch rejection without changing saved bytes.
- Persistent removal, absent-ID/empty-insert no-ops.
- Embedding-space/dimension mismatch and unknown schema version rejection.
- Malformed JSON, duplicate/corrupt records and byte-for-byte fail-closed behavior.
- Exact read-budget acceptance, oversized-write rollback and multi-read rejection.
- Deterministic filesystem write failure retaining the previous cache and corpus.
- Invalid configuration/nonregular input and typed cancellation for each operation.
- Concurrent inserts serialized through a single actor, retained after reopening.
- Protocol-level retrieval pipeline composition using existing mock embeddings.

The tests need no model asset, network, personal data or physical device. They
exercise atomic replacement failure, not process-kill/power-loss durability.

Validation: warning-free strict Swift build, 684 root Swift test functions and the
network-disabled suite, existing CustomTool/demo/EmbeddingProbe suites, 62 Python
tests, strict formatting/layering, DocC public API/static-route checks and generic
iOS demo build with signing disabled. Existing iOS metadata/orientation diagnostics
remain. The full suite's deliberately failed SwiftData migration can log Core Data
errors; those negative tests pass and are unrelated to this provider.
The initial example-demo test process exited with signal 11 before completion.
Two unchanged reruns passed all 12 functions; the crash cause is not established.
No assertion, test, runtime warning or feature was disabled to obtain the pass.

Core/Runtime coverage is 98.73% (2723/2758), down 0.07 percentage points from M3-03.
Core stays 99.27% (813/819); Runtime is 98.50% (1910/1939), versus 98.61% before.
Both source targets are unchanged; the difference is executed Runtime lines.

## Limits

This is small-corpus persistence: all records are cached, search scans O(N × D)
plus sorting, and mutations encode/rewrite the entire corpus. The byte budget is
not a peak-memory bound for decoded records, candidates, JSON or sorted results.
Snapshot text/vectors/metadata are plaintext; hosts own protected placement, file
access, backup/recovery, exclusive ownership and provider-backed file availability.
A local URL alone does not prove cloud-backed storage is resident or offline.

Cancellation is typed and checked before work, between reads/records/passages and
before commit. Native I/O/JSON, vector arithmetic and sorting already underway
cannot be forcibly interrupted; a completed write reports success even if cancelled
during that write. Actor isolation is not background ingestion/progress (M3-06).
No automatic migration, encryption, reindexing, demo storage change, physical-device
performance or realistic-corpus latency/memory acceptance is claimed (M3-08/10).

## Reproduce

```bash
swift build
swift test --filter FileVectorStoreTests
bash Scripts/check-coverage.sh
bash Scripts/check-offline-tests.sh
xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests Package.swift
bash Scripts/check-layering.sh
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
python3 Scripts/build-docs.py
python3 Scripts/check-docs.py .build/documentation/LocalAgentKit.doccarchive
xcodebuild -project Examples/LocalAgentDemo/LocalAgentDemo.xcodeproj \
  -scheme LocalAgentDemo -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/lak-store-ios CODE_SIGNING_ALLOWED=NO build
```
