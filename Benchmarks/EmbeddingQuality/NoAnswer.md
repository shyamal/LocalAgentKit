# Missing-answer evidence acceptance (M3-04)

A nearest passage can be topically related without containing the requested answer.
This benchmark measures passage acceptance under an explicit cosine threshold; it
runs no answer-generation model and does not measure hallucinations, truth,
refusals, permission safety or production answerability detection.

`corpus-no-answer.json` preserves the original 24 documents and 20 answerable queries
and adds ten project-authored missing-fact queries. Examples ask for a meeting URL,
a personal phone number, today's actual Wi-Fi code, or a final budget amount that
is not present. Some passages discuss those topics, but none supplies the requested
fact. Empty `relevant` lists mean no answer-supporting passage, not necessarily no
topical match. This is a deliberately small authored diagnostic, not independent
or representative validation. The original and independent SciFact fixtures are
unchanged.

## Explicit opt-in and metrics

The ordinary quality scorer still rejects empty relevance sets. Loading a no-answer
corpus requires `allow_no_answer=True`, and each empty relevance list must have
`answerable: false`. Contradictory/nonboolean annotations are rejected. The MLX
vector exporter accepts these validated annotations because embedding does not
depend on the labels; ordinary positive-only scoring remains strict.

The separate `score_abstention.py` command requires a finite threshold in [-1, 1].
It ranks every document by exact cosine, takes up to k, then retains only hits whose
score is **greater than or equal to** the threshold. A query is accepted if at least
one hit remains. This does not add a threshold or fallback to the SDK.

Reports distinguish:

- Missing-answer false acceptance: accepted no-answer queries / all no-answer queries.
- Answerable rejection: rejected answerable queries / all answerable queries.
- Accepted-query evidence precision: accepted queries with at least one supporting
  hit / all accepted queries. This is query-level, not passage precision or answer
  correctness; additional unsupported hits can still be present.
- Thresholded recall@k: macro-average fraction of supporting IDs retained for the
  answerable queries, including zero for rejected queries. Missing-answer queries
  have null per-query recall and are excluded from this denominator.

Accepted answerable queries with no supporting hit are counted separately; simple
acceptance does not count as evidence success. Undefined denominators are JSON null,
not a fabricated zero or perfect result. Scoring checks the corpus hash and vector
coverage/dimensions as before.

## Measured 2026-11-05

Apple silicon macOS 26.6.2 (25G83), Xcode 27.2 / Swift 6.4.2. NaturalLanguage English
sentence revision 1 (512 dimensions) and averaged words revision 1 (300 dimensions)
were measured separately. MiniLM uses the same pinned 4-bit model and isolated MLX
environment as the preceding measurements. All text fits the 256-token limit; no
truncation was enabled or performed. Thresholds 0.0, 0.5 and 0.75 were fixed in the
fixture's evaluation plan before measurement. All nine provider/threshold results
are retained in `results/no-answer-2026-11-05`, with provenance hashes.

| Path | Threshold | Missing-answer accepted / 10 | Answerable rejected / 20 | Thresholded recall@3 |
| --- | ---: | ---: | ---: | ---: |
| Sentence | 0.00 | 10 | 0 | 0.55 |
| Sentence | 0.50 | 1 | 14 | 0.15 |
| Sentence | 0.75 | 0 | 20 | 0.00 |
| Word average | 0.00 | 10 | 0 | 0.70 |
| Word average | 0.50 | 9 | 0 | 0.70 |
| Word average | 0.75 | 8 | 0 | 0.70 |
| MiniLM / MLX | 0.00 | 10 | 0 | 1.00 |
| MiniLM / MLX | 0.50 | 5 | 2 | 0.90 |
| MiniLM / MLX | 0.75 | 0 | 19 | 0.05 |

High cutoffs can reject the missing-answer queries while also discarding almost
all usable queries. The same numeric threshold is not calibrated equivalently
across embedding spaces. These illustrative profiles select no winning cutoff or
provider default; tuning against this fixture would not establish generalization.
A separate representative calibration set and held-out application data are still
needed under M3-07. Subsequent independent/Core AI measurements complete the
M3-04 benchmark under decision 0009; this diagnostic still supplies no calibrated
production threshold.

## Reproduce

Use the verified NaturalLanguage adapter and the cached optional MLX environment
from README.md to create exports with this corpus, then score each fixed threshold:

```bash
swift -swift-version 6 -strict-concurrency=complete \
  Benchmarks/EmbeddingQuality/export-natural-language.swift \
  Benchmarks/EmbeddingQuality/corpus-no-answer.json sentence /tmp/lak-no-answer-sentence-vectors.json
swift -swift-version 6 -strict-concurrency=complete \
  Benchmarks/EmbeddingQuality/export-natural-language.swift \
  Benchmarks/EmbeddingQuality/corpus-no-answer.json word-average /tmp/lak-no-answer-word-vectors.json
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  /tmp/lak-embedding-benchmark-venv/bin/python Benchmarks/EmbeddingQuality/export_mlx.py \
  Benchmarks/EmbeddingQuality/corpus-no-answer.json /tmp/lak-no-answer-mlx-vectors.json \
  --cache-dir /tmp/lak-embedding-model-cache
for provider in sentence word mlx; do
  for threshold in 0.0 0.5 0.75; do
    python3 Benchmarks/EmbeddingQuality/score_abstention.py \
      Benchmarks/EmbeddingQuality/corpus-no-answer.json \
      "/tmp/lak-no-answer-${provider}-vectors.json" \
      "/tmp/lak-no-answer-${provider}-${threshold}.json" --threshold "$threshold" --k 3
  done
done
```

Raw vector exports remain temporary local artifacts. Seven new offline test
functions cover acceptance/rejection denominators, absent support despite a hit,
threshold boundaries and per-hit filtering, null metrics, input rejection and
fixture preservation. Model packages remain optional benchmark-only dependencies;
no network, hardware or assets are needed for the default test suite.

## Verification

Warning-free package build, all 635 default Swift functions and the network-disabled
suite pass. Four custom-tool and twelve declared demo functions pass (the optional
native-fixture helper remains disabled). All 50 Python tests pass, including the
seven new missing-answer functions. Strict package/standalone-Swift formatting,
layering and DocC validation pass. Core/Runtime coverage is 98.80% (2634/2666),
0.04 percentage points above the preceding run with unchanged Core/Runtime source.
All nine reports reproduce exactly from measured vector exports; acceptance counts
balance and the original three positive-only synthetic reports are unchanged.
No new SDK/runtime dependency or model requirement enters the default test suite.
