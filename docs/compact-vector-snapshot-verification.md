# Compact vector snapshots (M3-12)

Verified on 2026-11-12. FileVectorStore now writes version-2 binary property lists.
Each record keeps its UUID, text and metadata, with its vector stored as
little-endian IEEE 754 Float32 bytes. This avoids encoding each component as a
JSON number and decoding the corresponding numeric JSON representation.

## Compatibility and state

Existing version-1 JSON snapshots remain readable. A read, empty insertion or
removal of absent IDs leaves the file intact. The first successful mutation
atomically replaces it with version 2. Older SDK versions that only implement
version 1 cannot read the migrated snapshot. Hosts that need to downgrade should
retain a backup before migrating.

The byte budget still applies to legacy files, compact reads and compact writes.
It remains 32 MiB by default. A legacy file exceeding that limit needs an explicit
larger budget to be opened and migrated. The format is detected by the binary
property-list signature; the configured file extension has no significance.

Both formats validate version, declared vector space, dimensions, unique IDs,
and finite nonzero vectors before publishing the cache. Compact records also
require exactly four bytes per component. Float32 bit patterns, including signed
zero and finite extremes, survive a compact round trip. Unsupported versions,
truncated data and corrupt records fail without rewriting the source.

The actor retains whole-corpus caching, exact cosine search, deterministic ties
and whole-snapshot atomic writes. Failed migration, encoding or replacement keeps
the previous file and cache. Cancellation is checked around records and before
commit. Foundation encoding/decoding and the atomic write run synchronously;
cancellation cannot interrupt a native call already in progress. A successful
commit remains success even if cancellation arrives immediately afterward.

## Pinned scale comparison

The unchanged M3-08 workload ran after other project builds completed on the
Apple M5 Max, macOS 26.6.2, Swift 6.4.2 host. All eight file preparations and
48 query processes completed, retaining all 1,440 timed queries. Raw results and
source, workload and executable hashes are in
[the compact run](../Benchmarks/RetrievalScale/results/macos-compact-2026-11-12/manifest.json).
The manifest's SDK commit is the clean base; its source hashes identify the
modified provider used to build the executable.

The table compares the prior M3-08 JSON run with this compact run. MiB uses
1,048,576 bytes. RSS is the highest whole-process high-water value among three
query processes. Load is the slowest fresh-instance load, with filesystem cache
state uncontrolled. Query p95 pools the same 90 warm timings per cell.

| Passages | Dims | JSON MiB | Compact MiB | JSON RSS MiB | Compact RSS MiB | Compact load ms | Compact query p95 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| 0 | 384 | 0.00 | 0.00 | 9.81 | 9.89 | 0.34 | 0.01 |
| 0 | 512 | 0.00 | 0.00 | 9.80 | 9.88 | 0.33 | 0.01 |
| 1,000 | 384 | 5.54 | 2.53 | 44.34 | 24.14 | 11.44 | 1.11 |
| 1,000 | 512 | 7.05 | 3.02 | 53.11 | 26.16 | 13.32 | 1.27 |
| 5,183 | 384 | 28.71 | 13.14 | 166.42 | 75.14 | 55.05 | 5.83 |
| 5,183 | 512 | 36.57 | 15.67 | 266.70 | 90.88 | 57.75 | 6.55 |
| 10,000 | 384 | 55.39 | 25.41 | 300.83 | 135.02 | 105.68 | 11.71 |
| 10,000 | 512 | 70.55 | 30.29 | 503.69 | 163.22 | 110.67 | 12.83 |

The 5,183 × 512 case now fits the existing 32 MiB snapshot budget and the
preselected exploratory 256 MiB host RSS target. All measured compact snapshots,
including 10,000 × 512, fit the default file budget. The largest compact case
still holds the entire corpus in memory and rewrites the full file on mutation.

Query p95 remains below 13 ms throughout the matrix, under the 100 ms host
investigation trigger. The benchmark supports retaining exact search and the
compact representation. Paging or ANN would add complexity without addressing
an observed budget failure in this workload.

These are capacity measurements with generated text and vectors. They exclude
embedding, model inference and end-to-end application work. Process RSS includes
runtime, file decoding and fixture allocations. The comparison is from separate
runs, and does not establish iPhone, thermal, battery or universal latency limits.

## Verification

Nineteen store functions pass, including four new regressions for legacy migration
and rollback, exact Float32 bytes, corrupt compact records and dense-vector
storage comparison. Existing tests continue covering whole-batch validation,
stable ranking, failed replacement, byte boundaries, cancellation and concurrent
inserts.

Warning-free SDK and release harness builds, all 728 package functions, the
network-disabled suite, 24 demo functions, seven probe functions, 70 Python tests,
strict formatting, layering, DocC and generic iOS build pass. The iOS build retains
the existing AppIntents metadata and orientation diagnostics.

Core and Runtime line coverage is 98.84% (2,896/2,930), up 0.03 percentage points
from the preceding PDF-fix run. Core remains 99.44% (889/894); Runtime is 98.58%
(2,007/2,036). Neither target's source changed.
