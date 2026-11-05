# Structure-aware chunking verification (M3-03)

Verified 2026-11-05. `ChunkerConfiguration.Strategy.structureAware` is the new
default; explicit `.wordAligned` keeps the preceding whitespace-normalizing
window behavior. Existing initializer calls remain source compatible, but default
boundaries for structured input change. Reindex existing vectors when changing
strategy; this task does not migrate stored embeddings or measure retrieval quality.

The Core implementation packs fitting paragraphs within literal ATX heading
sections. Fitting fenced blocks retain internal blank lines, and consecutive list
lines stay together as paragraph content. Structural boundaries are not overlapped.
Oversized blocks fall back to the existing whole-word windows and approximate
character overlap, with guaranteed forward progress even for oversized words.
All chunks retain source document identity, title and sequential index; sections
also carry the nearest literal heading in `sectionHeading` metadata. Chunk UUIDs
are fresh per call. This is source text, not trusted instructions or a citation.

Markdown cleanup previously removed heading/fence markers before chunking.
Tools now offers opt-in `preserveMarkdownStructure: true` on file extraction;
the default cleanup remains compatible. Raw memory Markdown can be passed as
plain text. PDF input offers only existing text-layer order/paragraph separators,
not inferred visual headings or layout.

## Verification scope

Twelve new Core tests cover intact paragraph packing, exact/Unicode boundaries,
ATX sections/metadata, adjacent/final headings, fenced content and matching runs,
unclosed fences, list lines, newline normalization, oversized blocks/words,
word fallback overlap/coverage/source identity, unsupported headings (including
isolated indented headings), blank/invalid input and legacy output. One Tools
integration test loads actual Markdown with preservation enabled and ingests it
through existing mock embedding/vector providers, checking section metadata and
unchanged default cleanup. No new protocol, runtime event, dependency or model call
is introduced; Core remains framework independent.

Validation passed: warning-free strict Swift build; 669 root Swift test functions
and the network-disabled suite; existing CustomTool/demo/EmbeddingProbe suites;
62 Python tests; strict formatting/layering; DocC API and static-route checks;
generic iOS demo build with signing disabled (existing metadata/orientation
warnings remain). Core/Runtime coverage is 98.80% (2725/2758), down 0.04 percentage
points from M3-02: Core 99.27% (813/819), Runtime 98.61% (1912/1939). Core coverage
increased; Runtime source is unchanged, with execution coverage variation.

## Limits

This is a lexical heuristic, not a Markdown AST, sentence tokenizer, OCR or layout
parser. Only unindented ATX headings with one to six markers plus whitespace are
recognized; Setext/indented headings and hierarchy reconstruction are unsupported.
Fences use backtick/tilde runs of at least three, with same-character closing runs
at least as long and only trailing whitespace. An unclosed fence extends to EOF.
Oversized fences/lists can split and need not remain syntactically valid Markdown.
Outer block whitespace is trimmed; CRLF/CR normalize to LF. Structure cannot be
recovered after upstream cleanup discards it. Single words may exceed the character
target, which is not a token budget; the runtime still counts its assembled prompt.
Blank/invalid configuration yields no chunks; callers should validate `issue`.
No async ingestion, progress or physical-device PDF acceptance is claimed.

## Reproduce

```bash
swift build
swift test --filter 'ChunkerTests|StructureAwareChunkerTests|DocumentExtractorTests'
bash Scripts/check-coverage.sh
bash Scripts/check-offline-tests.sh
xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests Package.swift
bash Scripts/check-layering.sh
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
python3 Scripts/build-docs.py
python3 Scripts/check-docs.py .build/documentation/LocalAgentKit.doccarchive
```
