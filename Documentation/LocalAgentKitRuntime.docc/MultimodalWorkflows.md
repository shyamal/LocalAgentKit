# Carry captured input into workflow tools

Bind normalized image, audio and document values directly to validated tool arguments.

## Capture in the host, orchestrate in the runtime

A host supplies authorized encoded image bytes through `AgentInput`. For example,
a camera or photo-picker callback can pass its selected image data to `run`.
The SDK does not open the camera or request photo-library access. Configure the
Vision operation appropriate for the task; default image classification does not
perform OCR.

The runtime invokes each input provider once, prepares structured values and
budgeted text excerpts, then starts the planner. A workflow can select a field
from the structured values without making the model copy it from its prompt:

```swift
let workflow = Workflow(
  name: "capture-note", description: "Save text from a captured image",
  steps: [
    .tool("save", "Save recognized text", "create_note", [
      "title": .literal("Captured text"),
      "body": .input(attachment: 0, path: "recognizedText.0.text"),
    ]),
  ])
let configuration = AgentConfiguration(
  model: FoundationModelProvider(),
  vision: try AppleVisionProvider(textRecognition: .init()))
let runtime = try AgentRuntime(
  configuration: configuration,
  tools: StaticToolSource([CreateNoteTool(store: noteStore)]),
  planner: StateMachinePlanner(workflow: workflow))
let response = try await runtime.run(AgentInput(
  text: "Save the first recognized text region as a note.",
  attachments: [.image(ImageInput(data: capturedImageBytes))]))
```

Import Core, Runtime, Providers and Tools. `noteStore` and `capturedImageBytes`
are host-owned. Subscribe to runtime events before `run` and present the
`permissionRequired` call for approval. `CreateNoteTool` writes only after the
host resolves that request with `resolvePermission(callID:approved:)`.
See <doc:BuildYourFirstAgent> for the event loop.

This example intentionally saves the **first OCR region**, not a complete receipt
or a parsed expense. Native OCR order and recognition accuracy are not guaranteed.
Semantic expense extraction and a camera UI belong to the receipt application.

## Structured value paths

`ArgumentSource.input(attachment:path:)` uses a zero-based attachment index and
a dot-separated object/array path. An empty path selects the whole normalized
value. `AgentContext.inputValues` exposes the same per-run values to custom
planners; `inputValue(attachment:path:)` performs optional lookup.

| Kind | Normalized fields |
|---|---|
| Image | `kind = "image"`, `classifications`, `recognizedText`, `detectedObjects`, `documents` |
| Audio | `kind = "audio"`, `text` (transcript) |
| Extracted document | `kind = "document"`, `title`, `text` |

Image classifications contain `identifier` and `confidence`. OCR entries contain
`text`, `confidence`, and `boundingBox`. Objects contain `labels` (classification
entries), `confidence`, and `boundingBox`. Documents contain `text`, optional
`title`, `paragraphs`, `tables`, `confidence`, and `boundingBox`.

Tables contain `rowCount`, `columnCount`, `cells`, and `boundingBox`. Cells contain
`text`, inclusive `rowStart`/`rowEnd` and `columnStart`/`columnEnd`, and `boundingBox`.
Every box is an object with `x`, `y`, `width`, `height`, using normalized lower-left
coordinates. Numbers retain JSON numeric types. Provider confidence is metadata,
not proof of accuracy or authorization.

Examples: `documents.0.tables.0.cells.0.text`, `recognizedText.0.boundingBox.x`,
`detectedObjects.0.labels.0.identifier`, and `text` for an audio attachment.
Paths cannot address working-memory bindings. Attachment values reset each run.

## Validation, trust and bounds

Missing indices/paths fail with typed invalid arguments; malformed paths and
negative indices are rejected during workflow validation. Input-derived values
are checked against their tool parameter schema **before** any model argument
extraction or permission request. The planner does not ask the model to repair
an incompatible source value. Literal, earlier-result binding and model argument
sources remain available for the other fields.

Input values are untrusted source data. Workflow selection and field selection
come from host code. Tool validation and permission enforcement still apply;
source text requesting a different tool or bypassing approval cannot change the
host-declared workflow. Choosing a read-only tool does not grant permission for
writes through another tool.

`AgentInputLimits.maximumStructuredBytes` defaults to 64 KiB for all attachments
in one run. Conservative accounting includes escaped strings, keys, numbers,
arrays and objects while building them. Oversized structured data and non-finite
numeric metadata fail before planning; no partial attachment values are exposed.
This cap is separate from the existing source and text-excerpt caps. Structured
values do not enter prompts automatically: only excerpts that survive normal
context budgeting do. Tool results later used in prompts follow existing
budgeting too. Neither limit bounds a provider's native working memory.

Normalization and direct bindings do not automatically persist raw input or
structured values. An approved tool may intentionally persist the selected data,
as this example does. Tool observations, answers, auditing and host subscribers
have their existing retention policies. Cancellation and run deadlines cover
normalization and subsequent tool execution; approval waits use the runtime's
existing human-wait policy.
