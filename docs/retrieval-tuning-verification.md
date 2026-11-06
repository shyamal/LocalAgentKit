# Retrieval selection controls (M3-07, partial)

Verified 2026-11-06 after rebasing onto merged M3-05 (d02bb1b). The branch
includes persistent storage but does not require the independent ingestion PR #62.
M3-07 remains in progress: selection controls are implemented, but no provider-specific
held-out application/no-answer calibration has been performed and no reliable cutoff
is claimed.

## Engineering behavior

Core RetrievalConfiguration configures positive result/candidate counts, an optional
finite inclusive score threshold and none/ID/exact-text/normalized-whitespace
deduplication. Its explicit defaults are five results, twenty candidates, exact-text
deduplication and no threshold. Candidate count must be at least the result count.

The explicit scored/text pipeline paths validate before provider calls, consider
only the first candidate window, drop nonfinite scores/blank passages, filter and
rank descending with store-order ties, deduplicate, then take the result count.
There is no refill or semantic deduplication. Original text, score, identity and
metadata remain; text policies may collapse identical wording across sources.
Thresholds use provider/store units rather than an assumed universal cosine range.
Existing AgentErrors remain typed, CancellationError maps to cancelled, and unknown
provider errors map to generic retrieval failure without copying raw diagnostics.
Cancellation is checked before work and after provider awaits.

Optional AgentConfiguration.retrieval and a throwing DocumentSearchTool initializer
share the path. Invalid settings fail before execution. Automatic RAG continues to
retrieve once and fit selected text through ContextBudgeter; genuine cancellation
remains terminal. Ordinary retrieval failures retain best-effort behavior. Existing
limit-only APIs, default automatic top-five retrieval and read-only permission tiers
stay unchanged. No new protocol, event/state, model, framework or dependency is added.

## Verification

Thirteen new Runtime test functions cover bounded candidate requests/consideration,
filter/dedup-before-top-k ordering, inclusive thresholds, finite scores/blank text,
stable ties, four duplicate modes, whitespace/case/punctuation behavior, preserving
legacy behavior, empty selections without claiming answerability, invalid settings
before provider calls, cancellation, typed errors and actual automatic-RAG context
injection. Two tool functions verify tuned dedup/no-results/read-only behavior and
construction-time rejection. These use deterministic existing-protocol test doubles,
not models or a retrieval-quality benchmark.

Warning-free strict build, **699** branch Swift functions and network-denied suite,
existing example suites (4 custom-tool, 12 demo, 7 probe), **62** Python tests, strict
formatting/layering, DocC API/link checks and generic iOS build with signing disabled
pass. Existing iOS metadata/orientation diagnostics remain; no warning is silenced.

Core/Runtime coverage is **98.76% (2795/2830)**, up 0.03 percentage points from
the merged M3-05 base. Core is 99.44% (880/885), versus 99.27% before; Runtime is
98.46% (1915/1945), versus 98.50% before. This task adds behavior in both targets;
the combined gate remains above 80%. No tests were adjusted to inflate coverage.

## Calibration still outstanding

The project-authored missing-fact diagnostic from M3-04 cannot select/certify a
production threshold. There is no independently annotated application/no-answer
corpus in this change. Do not invent labels from the implementation's outputs or
reuse calibration queries as held-out evidence. Score filtering can reject useful
passages while accepting topically related passages without the requested fact.

Before selecting a cutoff, freeze an authorized application corpus and independent
queries with supporting passage IDs, including explicit no-answer cases. Record
source/model/asset/tokenizer/pooling/fallback identity, chunking, truncation, dataset
hashes, source duplicate policy and split construction. Tune on calibration only;
run a locked configuration on untouched evaluation queries. Report acceptance of
missing-answer queries, rejection of answerable queries, supporting evidence recall,
undefined denominators and all tested settings. Ensure labels and query families do
not leak across splits. Current controls do not perform that measurement.

The DocC RetrievalSelection guide documents usage and these requirements. Once such
evidence exists, record the provider-specific operating point and its limits before
marking M3-07 complete. No physical-device or large-corpus resource claim is made.

## Reproduce

```bash
swift build
swift test --filter 'RetrievalSelectionTests|DocumentSearchToolTests'
bash Scripts/check-coverage.sh
bash Scripts/check-offline-tests.sh
xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests Package.swift
bash Scripts/check-layering.sh
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
python3 Scripts/build-docs.py
python3 Scripts/check-docs.py .build/documentation/LocalAgentKit.doccarchive
```
