# Full independent-corpus Core AI / same-checkpoint MLX quality

This extends the parity experiment from 44 authored fixture inputs to the full
checksum-pinned BEIR SciFact corpus: 5,183 candidate abstracts and all 300 test
queries, with 339 published positive judgments. No candidates or queries are
sampled based on model results. Raw dataset text, model assets, tensor fixtures
and vector exports remain local temporary data.

## Method

The original MiniLM checkpoint is pinned to
`1110a243fdf4706b3f48f1d95db1a4f5529b4d41`. Conversion uses PyTorch 2.13.0,
coreai-torch 0.4.3 and coreai-core 1.0.0b3 with the original unquantized weights,
eager BERT attention, mask-aware mean pooling and L2 normalization. The same
checkpoint's source file hashes are checked against the unquantized MLX export.
This is distinct from the earlier four-bit MLX community artifact.

`convert_minilm.py --allow-truncation` explicitly truncates model inputs to 256
tokens, pads to the fixed `[1,256]` contract, records counts and prepares PyTorch
reference vectors. Missing opt-in still rejects oversized input. Both original
MiniLM paths counted 3,681 truncated documents and zero truncated queries; the
longest original input contains 1,939 model tokens. Every actual inference uses
256 or fewer real tokens. HF's untruncated length preflight emits a >512-token
warning on some abstracts; that counted sequence is not passed to the encoder.
The conversion dependency also emits its existing TreeSpec deprecation warning.
Neither warning is silenced and neither is a Swift package build warning.

`run_host.py` executes every converted tensor through the official Python Core AI
runtime on macOS 26.6.2, checks Float32 `[1,384]` outputs, and refuses to publish
vectors if raw absolute error against PyTorch exceeds the unchanged 1e-4 limit.
`inspect_parity.py` independently recomputes the error and validates provenance,
coverage, shape, normalization and run identity before scoring. Compact ranking
reports retain ten IDs per query while recall@3/nDCG@3 and full-ranking MRR still
use all candidates. No partial dataset run is scored as a completed comparison.

The MLX exporter now offers `--original-minilm`; its default remains the earlier
pinned four-bit artifact. It uses the original source with no weight quantization.
Its maximum raw component difference from PyTorch is about 0.00113, despite matching
source files. Token IDs were checked and matched for the five largest-difference
rows. This is not 1e-4 MLX/PyTorch numerical parity; the cause of the remaining
implementation drift is not established. It is recorded rather than adjusting a
tolerance or calling all backends equivalent.

## Results, 2026-11-05

All 5,483 Core AI vectors passed raw parity at maximum absolute error
2.682209014892578e-7, below the fixed 1e-4 tolerance. No margin was relaxed.

| Path | Recall@3 | Full-ranking MRR | nDCG@3 |
| --- | ---: | ---: | ---: |
| Original MiniLM / Core AI | 0.6603 | 0.6113 | 0.5967 |
| Original MiniLM / PyTorch reference | 0.6603 | 0.6113 | 0.5967 |
| Original MiniLM / MLX | 0.6603 | 0.6107 | 0.5963 |
| Earlier four-bit MiniLM / MLX | 0.6405 | 0.6065 | 0.5877 |
| NaturalLanguage sentence | 0.0500 | 0.0572 | 0.0411 |
| NaturalLanguage word average | 0.1958 | 0.2029 | 0.1774 |

Per-query compact ranks, source/model hashes and numeric drift are recorded under
`results/coreai-scifact-2026-11-05`. M3-04's benchmark gate is complete under
decision 0009; production integration is M3-11, calibration M3-07 and realistic
resource validation M3-08/M6-05. No provider implementation/default changed.

## Reproduce

Prepare the pinned archive using `prepare_scifact.py` as documented in
`../IndependentCorpus.md`. Use the measured isolated environments from this folder's
README and `../README.md`, with cached checkpoints or explicit initial downloads:

```bash
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  /tmp/lak-coreai-venv/bin/python Benchmarks/EmbeddingQuality/CoreAI/convert_minilm.py \
  /tmp/lak-scifact-corpus.json /tmp/lak-coreai-scifact-new \
  --cache-dir /tmp/lak-coreai-model-cache --allow-truncation
/tmp/lak-coreai-venv/bin/python Benchmarks/EmbeddingQuality/CoreAI/run_host.py \
  /tmp/lak-scifact-corpus.json /tmp/lak-coreai-scifact-new \
  /tmp/lak-coreai-scifact-new-report.json --run-id <fresh-uuid>
python3 Benchmarks/EmbeddingQuality/CoreAI/inspect_parity.py \
  /tmp/lak-scifact-corpus.json /tmp/lak-coreai-scifact-new-report.json \
  /tmp/lak-coreai-scifact-new/reference.json /tmp/lak-coreai-scifact-new-quality.json \
  --expected-run-id <fresh-uuid> --ranking-limit 10
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  /tmp/lak-embedding-benchmark-venv/bin/python Benchmarks/EmbeddingQuality/export_mlx.py \
  /tmp/lak-scifact-corpus.json /tmp/lak-scifact-original-mlx-new.json \
  --cache-dir /tmp/lak-coreai-model-cache --original-minilm --allow-truncation
python3 Benchmarks/EmbeddingQuality/score.py /tmp/lak-scifact-corpus.json \
  /tmp/lak-scifact-original-mlx-new.json /tmp/lak-scifact-original-mlx-new-quality.json \
  --ranking-limit 10
```

The converted runtime consumes Int32 IDs/masks rather than the original PyTorch
Int64 tensor dtype. Source weights are unquantized and output arrays are Float32;
this does not establish every internal operation's precision or compute placement.
The model conversion artifact is about 86 MiB, not a process peak-memory figure.
Runs are not isolated/warmed consistently and are not resource/latency measurements.
The full-corpus Core AI run is on the Mac's Python runtime, not a new full-corpus
iPhone run. Earlier native iPhone parity covers the authored fixture only.

Scientific retrieval is not answer correctness, independently unseen training
examples, a future chunked RAG pipeline, real-user PDF acceptance or multilingual
coverage. The provider decision and task boundary are documented separately in
`docs/decisions/0009-embedding-quality-and-provider-policy.md`.

## Verification

Warning-free package build, all 635 main Swift test functions and the network-disabled
suite pass. Existing examples, seven portable probe functions and all 60 Python
tests pass. The new compact Core AI report regression preserves complete-rank MRR
when the first relevant candidate lies beyond the stored rank prefix. Strict
formatting, layering and final DocC validation pass. Core/Runtime coverage is 98.76%
(2633/2666), 0.04 percentage points below the preceding run with unchanged source
in both gated targets; Core stays 99.17%, Runtime is 98.61% versus 98.66% previously
(one fewer executed Runtime line). No coverage-target behavior was changed or tests
added to chase that variation. Provider source edits update documentation only.

All recorded per-query aggregates/full-rank reciprocals and report/source hashes
were checked. The original corpus and earlier measurements remain unchanged;
reports identify their own original source revisions. No model, raw vector export
or third-party dataset prose is committed, and default tests require no assets.
