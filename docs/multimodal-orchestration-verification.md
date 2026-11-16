# Multimodal workflow orchestration (M4-08)

Verified on 2026-11-16. This work builds on M4-07 / PR #78, which was still open
when implementation started. The branch is `codex/multimodal-orchestration`.

## Runtime path

Host-authorized captured image bytes enter AgentInput. InputPreprocessor invokes
Vision once and produces both budgeted text excerpts and normalized JSON values.
Audio/document attachments use the same ordered collection. AgentContext exposes
read-only inputValues, separate from working-memory bindings, model excerpts and
conversation memory. A new ArgumentSource.input(attachment:path:) selects a
zero-based attachment and an object/array field in code.

Image values preserve categories, OCR text/confidence/boxes, object labels and
confidence/boxes, and document text/title/paragraphs/tables/cell spans/boxes.
Audio values preserve transcripts; documents preserve title and text. Encoded
image/audio bytes are excluded. The workflow guide specifies the JSON field names.

Missing paths and absent attachments fail with typed invalid arguments, without
asking the model to supply replacement data. Malformed paths and negative indices
are invalid workflow configuration. The planner validates input-derived fields
against their parameter schemas before requesting any other model-derived fields.
All calls still use ToolExecutor validation, limits and permission enforcement.

A separate maximumStructuredBytes limit defaults to 64 KiB across all attachments.
Conservative incremental JSON accounting includes escaped strings, metadata,
container delimiters and keys, and checks cancellation while accumulating values.
Oversized structure and non-finite metadata fail before planning. This bound is
independent of source and excerpt limits; it does not bound native provider memory.
Text excerpts and later tool observations still pass through context budgeting.

No automatic input persistence was added. An approved tool can intentionally
persist its selected source data. Tool results, answers, auditing and host
subscribers retain their existing policies. Input values never become trusted
instructions or permission grants.

## Acceptance

Seven new runtime test functions cover approved/denied captured image calls,
combined audio/image/document paths, table-cell integer/string values, missing
and malformed paths, incompatible types without model repair, structured limits,
JSON escaping, non-finite metadata and isolation from other namespaces/later runs.
The existing eleven M4-07 functions also pass with structured normalization.

A portable demo integration exercises the real permission broker and CreateNoteTool:
no note exists at approval time; approval writes the selected text; denial leaves
the reopened NoteStore empty. The scripted model receives zero generation calls.

A gated native integration generated an image containing `INVOICE 42`, ran actual
AppleVisionProvider OCR on macOS, passed the recognized text through runtime
approval, and reopened the durable note with exactly the approved body. It passed:

```bash
LOCALAGENTKIT_DEVICE_TESTS=1 swift test --package-path Examples/LocalAgentDemo --filter NativeMultimodalPipelineTests
```

The native fixture uses the same installed CoreGraphics/CoreText/ImageIO image
construction already verified by the existing OCR tests. No new native provider
or capture API was introduced. No network, user photos or user records were used.

## Verification results

- Warning-free Swift build and full default suite: 818 registered functions.
- Core 99.29% (977/984), Runtime 98.73% (2329/2359), combined 98.89%
  (3306/3343). Combined coverage is down 0.04 percentage points from M4-07;
  Core is down 0.30 points with three additional executable lines and unchanged
  covered-line count; Runtime is up 0.09 points.
- Full offline suite passed on its first run for this task.
- Demo package: 26 registered functions (the native integration is gated by
  default); native OCR integration explicitly passed separately.
- EmbeddingProbe: seven functions; Python checks: 71.
- Strict formatting, architectural layering and DocC route validation passed;
  documentation contains 10,111 internal references.
- Generic iOS demo build passed. Existing AppIntents metadata and orientation
  warnings remain; library compilation is warning-free.

Logs are under `/tmp/lak-m408-`: build, focused, coverage, offline, demo, native,
probe, python, layering, format, docs and ios. The initial focused run found an
incorrect expected schema-message string in a new test; correcting that fixture
made the focused and subsequent full/offline suites pass.

## Remaining device acceptance

Camera/photo selection and capture permission UI remain host-owned, with the
receipt application in M4-11 providing that user flow. This acceptance proves the
SDK path from supplied captured bytes to a tool; it does not claim a physical
camera run, receipt field accuracy or an expense database implementation.

Successful native STT still needs installed assets and a known recording (M4-05).
Native speech cancellation and device resource measurements remain M4-09/10;
receipt and spoken-response demos remain M4-11/12. The generated-image test is a
mechanism check, not a quality benchmark.
