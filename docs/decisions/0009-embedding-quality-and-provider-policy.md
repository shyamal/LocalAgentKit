# 0009: Embedding quality and v0.3 provider policy

**Status:** Accepted, 2026-11-05 — resolves PLANNING question 4 and completes the M3-04 benchmark gate
**Relates to:** FR-013, FR-014, FR-015; PLANNING question 4; M3-04

## Question and scope

Which measured embedding path should guide v0.3 RAG, and is NaturalLanguage a
sufficient quality baseline? M3-04 gates implementation until this comparison and
provider decision are recorded. It does not define an accuracy threshold or require
all later corpus-scale resource, chunking, threshold and real-PDF tasks to be
completed first. Those remain explicit implementation and validation work.

## Evidence

The original authored fixture contains 24 passages and 20 queries. Subsequent
measurements preserve the checksum-pinned BEIR SciFact corpus: all 5,183 candidate
abstracts, all 300 test queries and 339 positive judgments. Neither candidate pool
nor queries were selected based on model results. Reports retain per-query ranks,
full-ranking MRR, source/model/input hashes and exact reproduction instructions.

The independent comparison uses the original unquantized MiniLM checkpoint
`1110a243fdf4706b3f48f1d95db1a4f5529b4d41` through PyTorch, MLX and converted Core AI.
Source file hashes match between the unquantized paths. All use a 256-model-token
limit; 3,681 documents and zero queries exceed it and are explicitly truncated.
NaturalLanguage receives the same full title-plus-abstract text, with its internal
sentence-window behavior unexposed by the API; averaged words skips OOV words.
This is a comparison of these actual configurations, not equal internals or a
chunked end-to-end RAG benchmark.

| Path | Recall@3 | Full-ranking MRR | nDCG@3 |
| --- | ---: | ---: | ---: |
| NaturalLanguage sentence | 0.0500 | 0.0572 | 0.0411 |
| NaturalLanguage word average | 0.1958 | 0.2029 | 0.1774 |
| Earlier four-bit MiniLM / MLX | 0.6405 | 0.6065 | 0.5877 |
| Original MiniLM / MLX | 0.6603 | 0.6107 | 0.5963 |
| Original MiniLM / PyTorch reference | 0.6603 | 0.6113 | 0.5967 |
| Original MiniLM / Core AI | 0.6603 | 0.6113 | 0.5967 |

All 5,483 converted Core AI vectors passed independent raw parity: maximum
absolute error 2.682209014892578e-7 against the fixed 1e-4 tolerance. These are
point results on this corpus, not a statistical-significance claim. Full ID-only
reports and provenance live in `results/coreai-scifact-2026-11-05` under the
embedding benchmark directory.

The earlier four-bit MLX artifact is reported separately; its gap must not be
attributed solely to quantization without establishing its original conversion
checkpoint. The unquantized MLX implementation also exhibits raw component drift
from PyTorch (maximum about 0.00113). Token IDs matched on the five largest-drift
rows checked; no cause or 1e-4 numerical-equivalence claim is inferred. Core AI
met the unchanged 1e-4 parity tolerance before its scores were published.

On one physical iPhone / iOS 27.2, both NaturalLanguage assets were present and
SDK default vectors matched the forced sentence path across all 44 authored
fixture inputs. Native converted Core AI also passed those 44 comparisons against
PyTorch at about 1.79e-7 maximum absolute error. Missing-asset fallback was not
reproduced on that phone. Assets/device behavior on other OS releases is unverified.
The small authored no-answer diagnostic shows that a fixed cosine cutoff alone
cannot establish whether the requested fact is present; no cutoff is calibrated.

## Provider policy

1. Retain the existing `NLEmbeddingProvider` API and demo wiring for compatibility,
   local system assets, the iOS/macOS 26.4 floor and zero added runtime dependencies.
   This does not certify its retrieval quality. Publish the weak measured baseline
   and keep the embedding seam replaceable; do not market it as broadly sufficient
   semantic retrieval based on the small successful demo.
2. Select unquantized MiniLM through Core AI as the next **opt-in integration
   candidate** for supported OS 27 hosts. It has a concrete conversion/execution path
   and source-reference parity checks, with measured retrieval compared separately
   from the four-bit MLX artifact. Add M3-11 for a production adapter using a
   host-supplied local model and tokenizer, explicit asset/network policy, mocks,
   cancellation and context-safe integration. No automatic model download, SDK
   dependency, public API or provider switch is introduced by this benchmark.
3. Keep provider-specific threshold/answerability calibration in M3-07, realistic
   corpus latency/memory in M3-08, full-session battery/thermal evidence in M6-05,
   and the real-user PDF integration check in M3-10. Supported-language quality
   remains a measured-scope limit; expanding language claims requires new evidence.
   None of these is silently marked complete by the quality comparison.

## Limits and consequences

Scientific retrieval is not representative application validation, proof of unseen
training data, answer correctness, multilingual quality or injection safety. The
benchmark uses complete abstracts rather than future structure-aware chunks.
The native Core AI test uses pretokenized fixture inputs, not a shipped Swift
WordPiece tokenizer or production `EmbeddingProvider`. The source model is
unquantized; model size is not peak process memory, and uncontrolled sequential
elapsed times are not latency/energy benchmarks. GPU preference does not establish
actual placement for every operation.

The decision resolves the embedding comparison/policy question within these limits;
it does not establish a universal accuracy target or change the deployment floor.
Full-corpus parity/results and repository checks pass, completing M3-04. Its
benchmark gate permits PDF/extraction/chunking/storage work; the new
optional provider still has its own explicit implementation task before the demo
can claim that higher-quality path is integrated.

## Evidence locations

- `Benchmarks/EmbeddingQuality/README.md`: original and independent baselines
- `Benchmarks/EmbeddingQuality/IndependentCorpus.md`: source labels and scoring
- `Benchmarks/EmbeddingQuality/NoAnswer.md`: acceptance/rejection diagnostic
- `Benchmarks/EmbeddingQuality/CoreAI/README.md`: conversion and native parity
- `Examples/EmbeddingProbe/README.md`: isolated physical app and verification limits
