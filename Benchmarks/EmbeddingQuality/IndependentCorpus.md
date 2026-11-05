# Independent retrieval corpus follow-up (M3-04)

The original 24-passage synthetic fixture remains unchanged. This follow-up measures
all 300 BEIR SciFact test queries against all 5,183 candidate abstracts, including
unjudged distractors. It uses the published positive relevance judgments; no labels
were generated, revised or selected based on model output. Training-only queries
are excluded, and the candidate pool is not reduced to known relevant documents.

SciFact is an external scientific-claim/evidence-retrieval dataset, not a sample of
this SDK's customer documents and not evidence of model training-set independence.
Relevant abstracts can support or refute a claim: these metrics measure retrieval,
not claim truth, medical correctness, answer generation or permission safety.
The published judgments are incomplete; unjudged candidates count as nonrelevant,
following the standard closed-qrels scoring convention. There are no no-answer,
multilingual or real-user PDF workloads in this run.

Sources and attribution:

- [SciFact data and paper, Wadden et al.](https://github.com/allenai/scifact)
- [BEIR dataset distribution and loader convention](https://github.com/beir-cellar/beir/wiki/Datasets-available)

The benchmark reads only a local checksum-pinned archive and extracts no ZIP members
to disk. It prefixes document/query IDs into separate namespaces and joins each
nonempty title and full abstract with a newline. Raw archives, converted text and
large vector exports remain local temporary artifacts. The repository stores only
numeric metrics, document/query IDs, ranked IDs and provenance hashes. Third-party
dataset text is not redistributed as Apache-2.0 SDK content; consult the dataset
sources for their terms before reuse.

## Results, 2026-11-05

| Encoder | Recall@3 | Full-ranking MRR | nDCG@3 |
| --- | ---: | ---: | ---: |
| NaturalLanguage sentence (English, revision 1, 512 dimensions) | 0.0500 | 0.0572 | 0.0411 |
| NaturalLanguage word average (English, revision 1, 300 dimensions) | 0.1958 | 0.2029 | 0.1774 |
| MiniLM L6 v2 4-bit / direct MLX (384 dimensions) | 0.6405 | 0.6065 | 0.5877 |

Measured on Apple silicon macOS 26.6.2 (25G83), Xcode 27.2 / Swift 6.4.2.
All 339 positive test judgments are retained; 23 queries have multiple relevant
abstracts. Reports and checksummed provenance live in `results/scifact-2026-11-05`.
The dataset/labels and full candidate pool were fixed before these measurements.

Sentence vectors perform poorly on this task, while MiniLM no longer achieves the
synthetic fixture's perfect result. These findings warrant further deployment and
application-domain evaluation, not silently promoting MiniLM or switching defaults.
No specialized scientific tuning was introduced.

## Encoder limits and report semantics

All encoders receive the same title-plus-abstract text. MiniLM uses its documented
256-token sentence-transformer limit. The new `--allow-truncation` flag explicitly
opts into tokenizer truncation and records how many documents/queries exceeded
that limit and the largest original token count. The default remains rejection
of oversized input. This run truncated 3,681 documents and zero queries; the
longest original input was 1,939 model tokens. No padding is needed with one input
per inference. The library provides normalized mean-pooled BERT text embeddings.

NaturalLanguage sentence and word-average paths remain forced rather than silently
falling back. Apple does not expose the sentence encoder's internal token/window
handling through this adapter; a full text argument does not prove the encoder
uses every word. The word-average path skips unknown words as before. These are
actual encoder configurations, not a controlled equal-token-window experiment.
No chunking, pooling across chunks, threshold tuning or reranking is introduced.

For each query, exact cosine similarity ranks every candidate. The new optional
`--ranking-limit 10` keeps the stored report compact; it does not restrict scoring.
Recall@3 and nDCG@3 use the top three candidates, while reciprocal rank uses the
first relevant candidate anywhere in the full ranking. Compact reports retain that
full `firstRelevantRank` even when it falls below the ten displayed candidates.
Default reports retain their previous shape and full rankings.

## Reproduce

Download the archive from the BEIR distribution above, then verify/convert it:

```bash
curl -L --fail \
  https://public.ukp.informatik.tu-darmstadt.de/thakur/BEIR/datasets/scifact.zip \
  -o /tmp/lak-scifact.zip
python3 Benchmarks/EmbeddingQuality/prepare_scifact.py \
  /tmp/lak-scifact.zip /tmp/lak-scifact-corpus.json
```

The converter requires archive SHA-256:
`536e14446a0ba56ed1398ab1055f39fe852686ecad24a6306c80c490fa8e0165`.
A changed download is rejected rather than silently defining a new benchmark.

```bash
swift -swift-version 6 -strict-concurrency=complete \
  Benchmarks/EmbeddingQuality/export-natural-language.swift \
  /tmp/lak-scifact-corpus.json sentence /tmp/lak-scifact-sentence-vectors.json
swift -swift-version 6 -strict-concurrency=complete \
  Benchmarks/EmbeddingQuality/export-natural-language.swift \
  /tmp/lak-scifact-corpus.json word-average /tmp/lak-scifact-word-vectors.json
```

Use the isolated optional environment from README.md for the pinned MLX model.
After its initial package/model download, inference can use the existing cache:

```bash
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  /tmp/lak-embedding-benchmark-venv/bin/python Benchmarks/EmbeddingQuality/export_mlx.py \
  /tmp/lak-scifact-corpus.json /tmp/lak-scifact-mlx-vectors.json \
  --cache-dir /tmp/lak-embedding-model-cache --allow-truncation
```

Score each vector file with the same corpus hash and candidate pool:

```bash
for encoder in sentence word mlx; do
  python3 Benchmarks/EmbeddingQuality/score.py /tmp/lak-scifact-corpus.json \
    "/tmp/lak-scifact-${encoder}-vectors.json" "/tmp/lak-scifact-${encoder}-report.json" \
    --k 3 --ranking-limit 10
done
```

Model and system-asset revisions remain those of the original baseline. The recorded
elapsed embedding passes have no controlled warmup/load and are not M3-08 latency,
memory or battery measurements. Library offline flags are not traffic-capture
proof. No physical-iPhone run or Core AI execution is claimed; M3-04 remains open.

## Verification

Warning-free package build, all 635 default Swift functions and the network-disabled
suite pass. Four custom-tool and twelve declared demo functions pass (the optional
native-fixture helper remains disabled by default). All 43 Python tests pass,
including five new independent-corpus/truncation/compact-ranking functions.
Strict package/standalone-Swift formatting, layering and DocC validation pass.
Core/Runtime coverage is 98.76% (2633/2666), unchanged from the preceding baseline;
no Core/Runtime source changes. The original three synthetic reports reproduce
unchanged through the default scorer. Compact independent reports were checked for
all 300 per-query metrics, aggregate consistency and reciprocal first-relevant rank.
No additional SDK dependency or model invocation enters the default unit suite.
