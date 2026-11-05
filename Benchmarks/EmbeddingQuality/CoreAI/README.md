# MiniLM Core AI conversion and numerical parity (M3-04)

This optional, benchmark-only path converts a pinned **unquantized original**
MiniLM checkpoint to `.aimodel`, runs that artifact through Apple's Python Core AI
runtime, and compares every raw output component to PyTorch before scoring retrieval.
It is not a conversion of, or numerical-parity claim about, the earlier four-bit
MLX artifact. It changes no SDK provider default or deployment floor.

## Verified 2026-11-05

Apple silicon macOS 26.6.2, Xcode 27.2 / Swift 6.4.2; `coreai-torch` 0.4.3,
`coreai-core` 1.0.0b3, PyTorch 2.13.0 and Transformers 4.57.3.

- Converted `sentence-transformers/all-MiniLM-L6-v2`, pinned source revision
  `1110a243fdf4706b3f48f1d95db1a4f5529b4d41`, with eager BERT attention,
  attention-mask mean pooling, and L2 normalization.
- Executed all **44 texts** (24 documents + 20 queries) through the saved Core AI
  artifact using the official Python runtime. The maximum absolute component
  difference from PyTorch was **2.0489096641540527e-7**, below the fixed **1e-4**
  tolerance. Source and Core AI outputs are normalized 384-component vectors.
- Input shape is `[1, 256]`, with **Int32** IDs and masks in the converted runtime;
  output is `[1, 384]` / Float32. The converter lowered the original PyTorch Int64
  inputs to Int32: the first Int64 runtime attempt was rejected. No truncation or
  dtype guessing is used by the final execution harness.
- Recall@3, full-ranking MRR and nDCG@3 are 1.0 for both PyTorch and Core AI on this
  small authored fixture. This does not establish independent or production quality.
- The initial environment selected PyTorch 2.15, which the converter warned was
  outside its validated range. That attempt is not the recorded artifact: conversion
  was repeated with PyTorch **2.13.0**. A dependency TreeSpec deprecation warning
  remains in that conversion; no warning is silenced.

The model asset is about 86 MiB and remains in local temporary storage, along with
raw tensor/reference/vector files. `results/coreai-host-2026-11-05` retains scored
ID-only outputs, model/package/input/artifact hashes and scope. No weights are
bundled in the Swift SDK or committed to this repository. Core AI/PyTorch Python
packages are optional measurement dependencies, not SDK runtime dependencies.

## Official API evidence

- [Apple's Core AI PyTorch quickstart](https://apple.github.io/coreai-torch/main/getting-started/quickstart.html)
  documents export, decomposition, conversion, asset saving and runtime invocation.
- [Apple's Core AI overview](https://developer.apple.com/documentation/coreai)
  distinguishes authoring/conversion from native app execution.
- Installed iOS 27.2 interfaces verify `AIModel.init(contentsOf:options:)`,
  `loadFunction(named:)`, `InferenceFunction.run(inputs:)`, `Outputs.remove(_:)`,
  `NDArray(scalars:shape:)`, typed views and `AIModelAsset.isValid(at:)`.

Swift framework APIs require iOS/macOS 27. The official Python package's authoring
and runtime execution were separately verified on this macOS 26.6.2 host; Swift
availability alone does not establish Python runtime compatibility either way.
The app's Core AI load command is `LC_LOAD_WEAK_DYLIB`, and execution is guarded
by `#available(iOS 27.0, *)`; the existing iOS 26.4 SDK floor remains unchanged.
A native launch on an older OS has not been performed in this follow-up.

## Reproduce conversion and host parity

Use a fresh output directory; conversion and execution refuse to overwrite previous
artifacts/reports so failed reruns cannot masquerade as fresh success:

```bash
python3 -m venv /tmp/lak-coreai-venv
/tmp/lak-coreai-venv/bin/pip install -r Benchmarks/EmbeddingQuality/CoreAI/requirements.txt
/tmp/lak-coreai-venv/bin/python Benchmarks/EmbeddingQuality/CoreAI/convert_minilm.py \
  Benchmarks/EmbeddingQuality/corpus.json /tmp/lak-coreai-minilm-new \
  --cache-dir /tmp/lak-coreai-model-cache
/tmp/lak-coreai-venv/bin/python Benchmarks/EmbeddingQuality/CoreAI/run_host.py \
  Benchmarks/EmbeddingQuality/corpus.json /tmp/lak-coreai-minilm-new \
  /tmp/lak-coreai-host-new.json --run-id <fresh-uuid>
python3 Benchmarks/EmbeddingQuality/CoreAI/inspect_parity.py \
  Benchmarks/EmbeddingQuality/corpus.json /tmp/lak-coreai-host-new.json \
  /tmp/lak-coreai-minilm-new/reference.json /tmp/lak-coreai-parity-new.json \
  --expected-run-id <fresh-uuid>
```

Initial package/checkpoint downloads require network access. The model loader uses
pinned safetensors/config/tokenizer data with remote code disabled. Source licensing
is the checkpoint publisher's Apache-2.0 metadata; converter packages carry their
own terms. Raw text is the existing original synthetic fixture, not user documents.
The exact dependency lock is the measured Python 3.14 environment; other Python
versions may not have matching wheels.

`inspect_parity.py` independently recomputes error from raw vectors, validates the
checkpoint identity, corpus, run UUID, dimensions, complete coverage and normalization,
and rejects fake zero-error summary fields. Failed/unavailable runs produce no
quality metrics and exit nonzero, while retaining a diagnostic JSON if available.
No score or tolerance is adjusted to make a conversion pass.

## Verified optional iPhone path

The isolated EmbeddingProbe app now has an explicit `LOCALAGENTKIT_COREAI_PROBE=1`
mode. It validates the transferred fixture, hashes every expected asset file, loads
the model, runs fixed Int32 tensors and compares Float32 outputs. Partial or failing
results contain no vector export. Cancellation is checked around model loading and
every inference. Ordinary probe runs do not load Core AI or require an artifact.
Legacy JSON reports still decode with the optional Core AI field absent.

The corrected signed app and generated fixture ran on the paired physical iPhone
on iOS 27.2 (24B115), after the user unlocked it. All 44 inputs completed; the
phone reported maximum absolute error 1.7881393e-7. Independent recomputation from
the exported JSON components gave 1.7850748443293263e-7, below the fixed 1e-4
tolerance. That independent check uses JSON-decoded components rather than the
device’s Float arithmetic. Recall@3, full-ranking MRR
and nDCG@3 were 1.0 on this fixture. Native result/provenance lives under
`results/coreai-iphone-2026-11-05`; no device identity, signing team or model weights
are committed. The initial locked-device launch was not treated as a model failure.
The previous physical run in PR #55 measured NaturalLanguage/SDK assets, not Core AI.
Its vector-comparison count was corrected from 40 to 44; the original comparisons
already covered all IDs and their numerical results are unchanged.

To reproduce, unlock the device and use the deployment instructions in Examples/EmbeddingProbe/README.md
and copy the complete conversion directory into only this app's container:

```bash
xcrun devicectl device copy to --device <device-id> \
  --domain-type appDataContainer --domain-identifier dev.localagentkit.embeddingprobe \
  --source /tmp/lak-coreai-minilm-new --destination Documents/CoreAI
xcrun devicectl device process launch --device <device-id> --terminate-existing \
  --environment-variables '{"LOCALAGENTKIT_EMBEDDING_AUTORUN":"1","LOCALAGENTKIT_COREAI_PROBE":"1","LOCALAGENTKIT_EMBEDDING_RUN_ID":"<fresh-uuid>"}' \
  dev.localagentkit.embeddingprobe
```

Retrieve `Documents/embedding-report.json` from that container after completion and
run `inspect_parity.py` with the same conversion's reference and run UUID. GPU is a
specialization preference, not proof every operation executes on GPU. Tokens are
precomputed by the pinned host tokenizer; this is not a shipped Swift tokenizer or
production `EmbeddingProvider`. Timing, battery, process peak memory and broad
application/multilingual/independent-corpus Core AI quality remain unmeasured.
M3-04 and PLANNING question 4 remain open.

## Verification of this follow-up

Warning-free package build, all 635 main Swift functions and the network-disabled
suite pass. Existing examples, seven portable probe functions, all 59 Python tests,
strict package/probe formatting, layering, workflow lint and DocC pass. Core/Runtime
coverage is unchanged at 98.80% (2634/2666); neither source target changed. Six new
Python functions exercise raw-error recomputation, forged summary fields, stale
runs, wrong checkpoint/shape/coverage, failed partial exports and failure exit status.
The new portable round-trip function covers optional Core AI data and legacy reports.
The corrected native code builds, is signed/installed, and completed the physical
iPhone parity run. The host inspector independently checked run identity, complete
coverage, normalized raw vectors and checkpoint provenance before publishing scores.
