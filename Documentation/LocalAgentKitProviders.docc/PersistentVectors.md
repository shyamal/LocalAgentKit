# Persist a local vector corpus

``FileVectorStore`` implements Core's `VectorStore` for small app-owned corpora
(FR-015, M3-05). It uses exact cosine search over a memory cache and a versioned
JSON snapshot on disk. It adds no runtime dependency, download, model call or
network request. It does not replace the demo's in-memory fixture store.

```swift
import LocalAgentKitCore
import LocalAgentKitProviders

let vectors = try FileVectorStore(
  url: authorizedStoreURL,
  embeddingSpace: "my-embedding/model-revision/tokenizer/pooling-v1",
  dimensions: 384)
let pipeline = RetrievalPipeline(embeddingProvider: embedding, vectorStore: vectors)
try await pipeline.ingest(document)
let passages = try await pipeline.retrieve(for: "Budget preparation")
```

The example dimension is illustrative: configure the actual embedding provider's
output size. Use exactly the same model, revision, tokenizer, pooling, normalization
and fallback behavior for indexing and queries. The host supplies an identifier for
that contract; the store cannot inspect the model behind a supplied vector. In
particular, asset-dependent sentence/word fallback can change embedding spaces.
Choose a stable path or a distinct store per space; do not mix vectors merely
because they have equal dimensions. Reopening with a different identifier or
dimension fails instead of silently searching incompatible data. Strategy changes
such as new chunk boundaries also require host-managed reindexing.

## Ownership and persistence

Share one actor instance per file. Independent instances, app extensions and other
processes are not coordinated. The store caches its first successful load and does
not watch external edits. Hosts own exclusive access, authorized/security-scoped
file access, backup, protected placement and recovery. Use a host-owned local
Application Support directory; no default location is chosen for you. A file URL
alone does not establish that backing storage is resident or offline: hosts must
control provider-backed availability and storage placement under their own policy.
Snapshots contain passage text, vectors and metadata in plaintext; no encryption,
backup exclusion or special file-protection policy is installed by the provider.

Only a missing file starts empty. Nonregular, unreadable, corrupt, oversized or
incompatible snapshots fail closed and are not replaced with an empty corpus.
Version 1 stores the embedding-space identifier, dimensions and passage records;
unknown versions and duplicate persisted IDs are rejected. No migration/downgrade
is attempted. Remove or archive incompatible data explicitly and re-embed through
the correct provider into a separate store.

Inserts upsert by passage ID; the last occurrence in a batch wins while the first
insertion position is retained. The entire batch is validated before persistence.
`remove(ids:)` durably removes known IDs; absent IDs and empty inserts do not write.
Re-ingestion generates fresh chunk IDs, so a host must remove the old passage IDs
when replacing a source document. `count()` loads lazily and returns unique IDs.

Each mutation encodes the entire candidate snapshot, writes atomically, then
publishes the new cache. Failed writes leave the cache unchanged. Atomic replacement
is not a power-loss durability, fsync or multi-process transaction guarantee.

## Search, limits and cancellation

Vectors must match the configured dimension, be finite and contain a nonzero
component. Queries are checked the same way; invalid values are typed retrieval
failures. Search uses Double arithmetic for cosine intermediates with Float scores,
ordered descending; equal Float scores use UUID strings ascending. Large/subnormal
finite Float components remain supported. Nonpositive result limits return no hits
after validating storage. No similarity threshold, deduplication by source text or
ANN index is added (M3-07/08).

`maximumBytes` defaults to 32 MiB. Reads use bounded chunks plus a one-byte limit
probe; writes reject encoded snapshots above the same budget. Limits must be
positive. The budget does not bound peak memory: loaded records, cached vectors,
candidate copies, encoding/decoding and sorted search results occupy memory.
Search is a full O(N × D) scan plus sorting, and every mutation rewrites the corpus.
This is a small-corpus implementation, not a scale/latency/battery benchmark.

Operations throw `AgentError.retrievalFailure` for configuration, vector, format or
I/O failures; cancellation throws `.cancelled`. Checks run before work, between
reads/records/search passages and before commit. Native file I/O, JSON processing,
vector arithmetic and sorting already underway cannot be forcibly interrupted.
After a successful atomic write the operation reports success even if cancellation
arrives during the write, preserving commit semantics. Actor isolation serializes
operations; it does not schedule a background ingestion job or emit progress
(M3-06). Hosts own ingestion scheduling. No physical-device performance or
large-corpus acceptance is claimed here.
