# Retrieval latency and memory (M3-08)

This standalone macOS harness measures the SDK's actual `InMemoryVectorStore` and
`FileVectorStore` in release mode. It does not alter SDK dependencies, provider
defaults, storage limits, model assets or demo behavior. The pinned workload is in
`workload.json`; raw samples, preparation measurements and hashes are committed
under `results/macos-2026-11-06`.

## Design fixed before the first measurement

- Zero-count controls plus 1,000 / 5,183 / 10,000 passages, 384 and 512 dimensions.
- Seeded dense normalized Float vectors, deterministic IDs, 1,024-character ASCII
  passages and fixed small metadata. These are capacity fixtures, not scientific
  embeddings or relevance/answerability labels. Passage count/dimension are realistic
  workload axes; this is not a representative user-PDF distribution.
- 20 candidates; five warmups and 30 measured distinct query vectors per process.
  Three fresh-process repeats per cell, with deterministic shuffled execution order.
- Separate snapshot preparation processes; each file query process loads its snapshot
  once before warmups. Filesystem pages can already be cached: this is fresh-instance
  read/JSON decode, not a cold-disk benchmark. Memory cases generate/populate before
  timing search; their initialization time is not directly comparable to file reopen.
- Whole-process `/usr/bin/time -l` maximum RSS and peak footprint in macOS bytes,
  measured separately for preparation/query processes. These are high-water process
  metrics including runtime/JSON/fixture allocations, not live heap or index-only
  resident bytes. Zero controls are retained rather than subtracted from peaks.
- Nearest-rank p50/p95, all 90 samples pooled per cell, with all raw per-repeat samples retained. Repeats reuse the same query sequence; this is not
  an independent statistical sample of applications or a confidence interval.
- Exploratory host planning targets at 5,183 passages: query p95 ≤100 ms, fresh-file
  load ≤1,000 ms, whole-process peak RSS ≤256 MiB. These are preselected investigation
  triggers, not PRD SLAs or iPhone acceptance. ANN investigation is triggered only
  by query-budget failure in at least two repeats; memory/load failure alone calls
  for storage/cache analysis before an ANN decision.
- File runs explicitly use a 256 MiB test byte budget so the larger snapshots can be
  measured. The SDK default remains 32 MiB; every report records whether it would fit.

## Measured 2026-11-06

Apple M5 Max, 36 GiB physical memory, macOS 26.6.2 (25G83), Swift 6.4.2.
The harness invokes no embedding/model or networking API; no traffic-capture
certification is claimed. The runner
records SDK commit, source/workload/binary hashes, host/toolchain information and
all 48 query processes plus eight preparation processes. Hardware results are not
CI pass/fail thresholds and must not be generalized to a phone.

| Store | Passages | Dims | Search p95 ms | Max sample ms | Query-process peak RSS MiB | Max fresh load ms | JSON MiB | Fits default 32 MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| file | 0 | 384 | 0.01 | 0.02 | 9.8 | 0.33 | 0.0 | yes |
| file | 0 | 512 | 0.01 | 0.01 | 9.8 | 0.30 | 0.0 | yes |
| file | 1,000 | 384 | 1.29 | 1.41 | 44.3 | 61.58 | 5.5 | yes |
| file | 1,000 | 512 | 1.33 | 1.44 | 53.1 | 81.45 | 7.1 | yes |
| file | 5,183 | 384 | 5.20 | 5.23 | 166.4 | 305.85 | 28.7 | yes |
| file | 5,183 | 512 | 5.79 | 5.92 | 266.7 | 406.50 | 36.6 | no |
| file | 10,000 | 384 | 11.17 | 11.48 | 300.8 | 581.31 | 55.4 | no |
| file | 10,000 | 512 | 12.05 | 12.20 | 503.7 | 788.83 | 70.6 | no |
| memory | 0 | 384 | 0.01 | 0.01 | 9.3 | — | 0.0 | yes |
| memory | 0 | 512 | 0.01 | 0.02 | 9.3 | — | 0.0 | yes |
| memory | 1,000 | 384 | 0.49 | 0.51 | 13.2 | — | 0.0 | yes |
| memory | 1,000 | 512 | 0.56 | 0.58 | 14.0 | — | 0.0 | yes |
| memory | 5,183 | 384 | 2.28 | 2.34 | 27.6 | — | 0.0 | yes |
| memory | 5,183 | 512 | 2.77 | 2.93 | 32.1 | — | 0.0 | yes |
| memory | 10,000 | 384 | 4.64 | 4.78 | 44.3 | — | 0.0 | yes |
| memory | 10,000 | 512 | 5.49 | 5.63 | 53.0 | — | 0.0 | yes |

“Fits default” is applicable only to file snapshots; memory rows persist no JSON.
The largest file preparation process (10,000 × 512) took 985.4 ms including fixture
generation/encoding/write and peaked at 369.2 MiB RSS. Read/decode high-water RSS
can exceed preparation RSS; neither is a steady-state index measurement.

## Decision and limits

Do not add ANN from this evidence. Every warm-query cell stays below the 100 ms
investigation threshold, including the larger stress cells. Exact search remains
the measured baseline for this host/workload; no universal scale limit is inferred.

Storage is the limiting observation: the 5,183 × 512 fixture is 36.6 MiB and fails
the default byte budget; its query-process RSS peak is 266.7 MiB, above the pinned
256 MiB host target. The 10,000 × 512 stress fixture reaches 70.6 MiB JSON and
503.7 MiB query-process RSS. Merely raising the file limit does not solve peak
allocation. M3-12 tracks compact/paged snapshot and decode/cache investigation,
with the same measurements and compatibility/cancellation checks before changing
formats or defaults. No storage implementation is changed in this task.

This measures exact store search only, excluding embedding generation, scored
pipeline filtering, ingestion scheduling, context fitting, model inference and
answer generation. There is no threshold calibration, recall-quality/ANN comparison,
thermal/battery measurement, physical-iPhone measurement or real-PDF acceptance.
File shape, Unicode/escaping, dimensions, OS cache, hardware and background load
can change results. A phone budget still needs a physical-device run before a
phone performance claim (M6-05/M3-10); desktop headroom cannot certify it.

## Compact snapshot follow-up (M3-12, 2026-11-12)

The same matrix now measures version-2 compact FileVectorStore snapshots, with
all raw results under `results/macos-compact-2026-11-12`. The 5,183 × 512 file
falls from 36.6 MiB to 15.7 MiB, and its query-process peak RSS falls from
266.7 MiB to 90.9 MiB. All compact cells fit the default 32 MiB file budget.
Query p95 stays below 13 ms. The table above is the historical JSON baseline.

See [compact snapshot verification](../../docs/compact-vector-snapshot-verification.md)
for the complete comparison, version-1 read compatibility, migration behavior and
validation. The benchmark workload and its exploratory host targets are the same.

## Reproduce

```bash
swift build -c release --package-path Benchmarks/RetrievalScale
scale_binary="$(swift build -c release --package-path Benchmarks/RetrievalScale --show-bin-path)/RetrievalScale"
python3 Benchmarks/RetrievalScale/run.py --binary "$scale_binary" --output /tmp/lak-scale-new-run
python3 -m unittest discover -s Scripts/tests -p 'test_retrieval_scale.py'
```

Run on macOS with process resource accounting permitted. Missing/invalid `time`
metrics fail instead of being treated as zero. The output directory must be empty;
existing measurements are not overwritten. Native failures are recorded and abort
the matrix; partial output is not a complete result. Do not select only fast cases
or remove outliers. Snapshot files are created in a temporary directory and removed
afterward; generated passage/vector payloads and model weights are not committed.

## Verification for this change

The standalone release build is warning-free. All 713 SDK Swift test functions and
the network-denied SDK suite pass; Core/Runtime coverage is 98.87% (2897/2930),
unchanged from the base branch's preceding run. All 70 Python tests pass, including
eight benchmark checks for sample/metric validation, complete cases/repeats,
assessment rules and recomputing the committed summary from every raw run.
Strict Swift formatting covers both SDK and standalone benchmark sources; layering
and diff checks pass. Workload/harness/provider hashes match the measured sources.
No SDK source or iOS API changed, so iOS/example/DocC builds were not repeated for
this standalone developer-harness task. The benchmark does not run in default CI;
only deterministic Python mechanics/artifact checks run there.
