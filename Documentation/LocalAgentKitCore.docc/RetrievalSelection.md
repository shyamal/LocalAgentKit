# Select bounded retrieval evidence

Use ``RetrievalConfiguration`` with ``RetrievalPipeline`` to control top-k,
score filtering and repeated passages (M3-07). These settings select candidates;
they cannot determine whether the requested answer exists in a passage.

```swift
let selection = RetrievalConfiguration(
  resultLimit: 3, candidateLimit: 20, deduplication: .normalizedWhitespace)
let hits = try await pipeline.search(for: query, configuration: selection)
let passages = try await pipeline.retrieve(for: query, configuration: selection)
```

Explicit settings default to five results, twenty candidates, exact-text deduplication
and no score threshold. The preceding `retrieve(for:limit:)` overload remains
unchanged: it requests the limit directly and preserves store order/duplicates.
No scored selection is silently applied to existing callers.

## Order and bounds

The explicit path validates configuration before embedding, requests one bounded
candidate window, and considers at most that many returned entries even if a custom
store returns more. It discards nonfinite scores and blank text, applies an optional
inclusive minimum score, ranks descending (original store order breaks ties), then
deduplicates before taking the result limit. There is no refill request; duplicates
or filtering can produce fewer than the requested results. Increase the candidate
window deliberately when appropriate, considering provider cost and memory.

Deduplication modes are none, passage ID, exact Swift string equality (including Unicode canonical equivalence) or normalized whitespace.
Whitespace normalization collapses Unicode whitespace runs to a single space for
comparison only. Case/punctuation remain significant. The highest-ranked occurrence
keeps its original text, identity and metadata. This is not semantic deduplication,
source-level grouping or automatic removal of overlapping chunks. Exact-text policies
can collapse identical wording from different sources; choose passage-ID/none when
source provenance must remain separate.

Result limits must be positive and candidate limits at least as large. An optional
minimum score must be finite; scores are in the store's own units, so the API does
not enforce a universal cosine range. Existing AgentErrors are preserved, CancellationError maps to `.cancelled` and
unknown provider errors become a generic `.retrievalFailure`. Cancellation checks run before work and after provider awaits, including providers
that return despite cancellation. Score sorting/string processing already running
cannot be forcibly interrupted. Candidate count is not a total byte/memory bound.

## Runtime and tool use

`AgentConfiguration.retrieval` optionally applies these settings to automatic RAG;
nil preserves the old top-five path. The runtime validates settings at construction,
retrieves once per run, and routes selected text through the same context fitting.
Retrieval remains best effort except cancellation, which is terminal. Fewer selected
passages never bypass token budgeting or change permission gates.

The Tools `DocumentSearchTool` initializer accepting `retrieval:` validates settings
before execution. Its existing `limit:` initializer keeps the previous behavior.
The tool remains read-only; empty selections retain the existing no-results result.
Ordinary provider failures still degrade as before, while cancellation propagates.

## Threshold calibration remains required

`minimumScore` defaults to nil. There is no recommended or calibrated cutoff. The
same number can behave differently across embedding model/revision/tokenizer/pooling,
asset-dependent fallback and store similarity scale. A high score can mean topical
similarity without supporting the requested fact; a high threshold can suppress
usable evidence. Previous project-authored missing-fact profiles are diagnostics,
not held-out application/no-answer calibration (decision 0009).

Before adopting a cutoff, use independently annotated application queries, including
missing-answer cases and supporting passage IDs. Freeze corpus/provider/chunking,
source-level duplicate policy, candidate/result limits and calibration/evaluation
splits before tuning. Choose settings on calibration only and report the untouched
evaluation split, including false acceptance, false rejection, supporting-evidence
recall and undefined denominators. Do not tune and certify on the same queries.
Record model/asset revision, vector-space identity, dataset hashes, truncation and
all tested settings. Changing any of these requires revisiting calibration.

No such held-out application corpus or selected cutoff is supplied by this change.
M3-07 therefore remains in progress after the engineering controls land. These
controls add no model, runtime dependency, protocol or claim of answer correctness.
