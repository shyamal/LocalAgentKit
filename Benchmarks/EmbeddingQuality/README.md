# Embedding quality baseline (M3-04, gate still open)

This standalone measurement harness compares exact-cosine retrieval on a fixed,
original synthetic English workplace corpus. It adds no SDK/runtime dependency,
changes no provider default, and runs no model in CI. It is independent of the demo conversation-resume integration.

The corpus has 24 passages and 20 queries with binary relevance judgments, including
paraphrases, similar-topic distractors, a multi-relevant query, and literal queries.
Labels were fixed before the first measurements and were not adjusted after seeing
results. The author of this benchmark also authored the labels; they are not an
independent ground truth or representative customer dataset. All queries have at
least one relevant passage. There is no no-answer, multilingual, long-document,
chunking, injection-resistance, or confidence-threshold assessment here.

## Measured 2026-11-05

Apple silicon Mac, macOS 26.6.2 (25G83), Xcode 27.2 (27B52), Swift 6.4.2.

| Embedding path | Dimension | Recall@3 | MRR (full ranking) | nDCG@3 |
| --- | ---: | ---: | ---: | ---: |
| NaturalLanguage English sentence, revision 1 | 512 | 0.550 | 0.480 | 0.445 |
| NaturalLanguage English averaged words, revision 1 | 300 | 0.700 | 0.633 | 0.608 |
| MiniLM L6 v2, 4-bit, direct MLX | 384 | 1.000 | 1.000 | 1.000 |

`results/` contains full per-query rankings, category aggregates and immutable input,
weight/tokenizer and vector-export hashes. The large raw vector exports are temporary
local artifacts, not bundled SDK resources; reproduce them with the commands below.
Asset revision does not identify Apple's exact internal weights across OS releases;
OS and requested path are recorded as well. Sentence and word paths fail if their
requested asset is missing: no silent fallback during measurement. Word averaging
mirrors the SDK's tokenizer/OOV-skipping behavior, with Double accumulation rather
than the SDK's final Float conversion. Exact cosine rankings use normalized Doubles
and stable ID ordering for ties. This is not the SDK vector-store latency benchmark.

Recall@k is the fraction of relevant documents in the first k results, averaged
per query. MRR uses the first relevant rank across the full corpus (not MRR@3).
nDCG@k uses binary relevance and log2 discounts, normalized to the ideal ranking.
Category results are macro averages within each category; scores are not calibrated
probabilities and should not be compared across embedding spaces as thresholds.

MiniLM is promising on this fixture, not a general quality winner. The fallback
outperforming sentence vectors is specific to this run; preserve both baselines.
Do not tune the provider or retrieval thresholds against these same twenty queries.

## Reproduce the NaturalLanguage paths

```bash
swift Benchmarks/EmbeddingQuality/export-natural-language.swift \
  Benchmarks/EmbeddingQuality/corpus.json sentence /tmp/lak-sentence-vectors.json
swift Benchmarks/EmbeddingQuality/export-natural-language.swift \
  Benchmarks/EmbeddingQuality/corpus.json word-average /tmp/lak-word-vectors.json
python3 Benchmarks/EmbeddingQuality/score.py Benchmarks/EmbeddingQuality/corpus.json \
  /tmp/lak-sentence-vectors.json /tmp/lak-sentence-report.json --k 3
python3 Benchmarks/EmbeddingQuality/score.py Benchmarks/EmbeddingQuality/corpus.json \
  /tmp/lak-word-vectors.json /tmp/lak-word-report.json --k 3
```

NaturalLanguage APIs were checked in the installed NLEmbedding.h and compiled/run
against the SDK. Both adapters require locally installed assets. CLI asset presence
does not establish availability in an iPhone app; that distinction caused the demo's
original missing-sentence-asset issue.

## Optional direct-MLX comparison

The comparison uses the model author's [MLX MiniLM conversion](https://huggingface.co/mlx-community/all-MiniLM-L6-v2-4bit/tree/128ca2da88d925829a17fb5ddfdc86b42eb58fb2),
revision `128ca2da88d925829a17fb5ddfdc86b42eb58fb2`, Apache-2.0 model metadata.
It loads safetensors/config/tokenizer data only, with remote code disabled, using
[mlx-embeddings](https://github.com/Blaizzy/mlx-embeddings)' documented BERT
mean-pooled normalized `text_embeds`. The pinned tool is GPLv3 and MLX is MIT;
these are optional measurement-environment dependencies, not linked, vendored or
redistributed in the Apache-2.0 Swift SDK. Review their terms before reusing that
external tooling in a distributed product. No package source was copied here.

```bash
python3 -m venv /tmp/lak-embedding-benchmark-venv
/tmp/lak-embedding-benchmark-venv/bin/pip install \
  -r Benchmarks/EmbeddingQuality/requirements-mlx.txt
/tmp/lak-embedding-benchmark-venv/bin/python Benchmarks/EmbeddingQuality/export_mlx.py \
  Benchmarks/EmbeddingQuality/corpus.json /tmp/lak-mlx-vectors.json \
  --cache-dir /tmp/lak-embedding-model-cache
python3 Benchmarks/EmbeddingQuality/score.py Benchmarks/EmbeddingQuality/corpus.json \
  /tmp/lak-mlx-vectors.json /tmp/lak-mlx-report.json --k 3
```

Environment versions are pinned from the measured Python 3.14 environment. Other
Python/OS versions may lack matching wheels. Initial package/model setup requires
network downloads; input text is processed locally. Cached inference was repeated
with `HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1` successfully; that is library offline
configuration, not an OS-level traffic-capture claim. The model has a 256-token
sentence-transformer limit; by default the adapter rejects longer input. The
independent-corpus run explicitly opts into counted tokenizer truncation with
`--allow-truncation`. Recorded elapsed times are one sequential pass without warmup or a
controlled load, not latency, energy or memory benchmark results (M3-08).

## Independent-corpus follow-up

See [IndependentCorpus.md](IndependentCorpus.md) for the checksum-pinned BEIR
SciFact import, full-candidate published-label evaluation, explicit MiniLM
truncation accounting and compact full-ranking reports. The original synthetic
corpus/results remain unchanged and independently reproducible.

## Gate follow-up

M3-04 and PLANNING question 4 remain open. Before making the deployment/provider
decision and starting gated RAG expansion:

1. Add independent, representative document/query judgments and no-answer cases,
   languages and long-document/chunking workloads relevant to real users.
2. Measure physical-device asset availability, retrieval quality, memory, latency
   and thermal/energy implications on supported OS/device combinations.
3. Resolve the task's explicit “via Core AI” deployment framing. This measured
   comparison runs MLX directly, not through CoreAIRuntime. The existing SDK findings
   identify Core AI as a tensor API; no validated converted MiniLM/Core AI execution
   path is supplied or claimed by this work. Do not silently waive that requirement.

Offline scorer tests run with the repository's existing Python CI command:

```bash
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
```

The scorer rejects changed corpus hashes, missing/extra vectors, zero/nonfinite or
incompatible vectors, and invalid relevance IDs. It never compares mixed embedding
spaces. Tests cover full-rank MRR, multiple relevance judgments, tie ordering,
normalization, macro/category averaging and malformed input.

## Verification of this baseline change

The warning-free package build, all 632 default Swift test functions and the
network-disabled suite pass on this branch. Four custom-tool tests, seven demo
planner tests and all 38 Python tests (including seven new scorer functions) pass.
Strict format lint covers the package and standalone Swift adapter; the layering
check and DocC validation (9,115 internal topic references) pass. The standalone
adapter also compiles/runs with Swift 6 complete strict-concurrency checking.
Core/Runtime coverage is 98.76% (2633/2666), unchanged from the preceding main-branch
memory-coverage result; no Core/Runtime source changed.
