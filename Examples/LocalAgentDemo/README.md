# LocalAgent Demo

The MVP reference application (PRD §13, TASKS.md M1-UI-03..08): a four-turn conversation that
demonstrates **Reasoning + Tools + Memory + RAG + Permissions + Actions** end to end, on the real
on-device model.

It's a separate Xcode project, not part of the Swift package, so it can't affect the package's
build, coverage, lint, or layering gates — the same reasoning as `Spike/`.

> [!IMPORTANT]
> **`LocalAgentDemo` does not run on iOS Simulator.** The on-device generative model is not
> available there at all — Apple's own framework throws `InferenceError::operationNotAllowed::
> Simulator is not supported`, found by testing (Simulator's console log, not documented anywhere
> we could find beforehand). Every model call fails immediately. Use the **macOS** build (this
> Mac, no device needed) or a **physical iPhone** — see *Build and run* below. `Simulator not
> supported` surfaces as an untyped, unhelpfully generic error from deep in the framework
> (`Model Catalog error ... Code=5000`); earlier versions of this provider's error mapping
> misclassified it as `AgentError.contextLimitExceeded`, which is a separate, real, and much
> rarer failure — see `ErrorMapping.swift`'s `isTokenGenerationFailure`.

## The four turns

| You say | What happens |
|---|---|
| "What meetings do I have tomorrow?" | `CalendarTool` reads your real calendar |
| "Find my notes related to those meetings." | `DocumentSearchTool` searches bundled fixture notes via RAG (see below) |
| "Create a preparation checklist." | Pure reasoning — no tool call, the model writes from context |
| "Save that as a note." | `CreateNoteTool` — held for your confirmation first (the permission flow) |

**The fixture notes are not correlated to your real calendar.** `Resources/notes.md` bundles a
few generic example notes (a budget review, a project sync, an onboarding checklist) so the
second turn has real content to retrieve — the demo proves the retrieval *mechanism* end to end,
not a scripted match between two independent real data sources (your actual calendar and a
canned note). Turn 2's answer quality depends on whether anything you actually asked about in
turn 1 resembles that bundled content.

**End-to-end reliability is bounded by what Phase 0 measured, not guaranteed.** The canonical first prompt uses an application-selected calendar workflow:
code computes tomorrow in the runtime timezone, reads once, then displays the actual calendar result with local event times and
the queried date/timezone; the model does not rewrite this answer. This also handles an empty calendar. The canonical second prompt also uses a single-search workflow: the model
extracts search terms from the earlier meetings, the tool runs once, and its
actual passages and query are displayed directly. The model does not rewrite
retrieval results; ranked passages are not guaranteed relevant matches. Empty results finish without a retry. The canonical checklist prompt uses one
answer step with the recent conversation and no tools. The canonical save prompt passes the completed checklist text directly to
`create_note`, preserving the approval gate and avoiding model reconstruction.
Without a completed checklist it does not write. Other wording uses open mode. Single-call tool accuracy measured 51–63% in Phase 0
(`docs/phase-0-findings.md` §11); a real run may need the argument-repair path, or may occasionally
pick the wrong tool. That's the honest, measured state of R1, not a demo bug.

For the physical-device milestone exit check, follow
[Device validation](DEVICE-VALIDATION.md). It covers conversation continuity,
confirmation before saving, stored-note verification and denial.

## Saved local notes

`NotesTool.tools` registers `CreateNoteTool` (confirmation required) and
`SearchNotesTool` (read-only) over the same file-backed `NoteStore`. Existing
Application Support `notes.json` data remains compatible. Other prompts can search
saved notes, for example “Search my saved notes for Budget review.” Open-model
selection remains subject to the measured reliability limits above.

The canonical second turn still searches bundled RAG fixture notes; it does not
search this saved-note store. The canonical fourth turn saves the exact completed
checklist after approval. Corrupt/unreadable saved-note files now report a typed
failure instead of being silently replaced with an empty collection.

## Thermal behavior

The agent also samples device thermal state at work boundaries through
`ProcessInfoThermalStateSource`. Fair/serious pressure tightens the next context
budget; critical pressure rejects new model/tool work with a cooling message.
It does not interrupt in-flight work or continuously observe idle periods.
Physical-device battery improvement and overhead have not been measured.

## Permissions

Calendar and Reminders need the user's authorization the first time each runs — both the modern
(`NSCalendarsFullAccessUsageDescription`, `NSRemindersFullAccessUsageDescription`) and legacy
usage-description keys are set in `project.yml`, since which one the OS reads at this floor isn't
documented in the SDK headers. **This is the one thing that can't be verified by an automated
build:** the authorized path needs a human clicking "Allow" once, in a real app bundle — which is
exactly what this project is, unlike a bare SwiftPM test binary (`EventStoreProvider`'s own doc
comment notes the same limitation).

## `LocalAgentDemoUIKitCheck`

A second, deliberately minimal target (M1-UI-08): one view controller that builds an
`AgentRuntime` and runs a turn, with **no dependency on `LocalAgentKitSwiftUI`** anywhere in its
target or its imports. If it builds and runs, the claim that a UIKit consumer gets full
functionality without being forced into SwiftUI is demonstrated, not just asserted. It uses a
`MockModelProvider`, not the real model — this target verifies the *layering* claim;
`FoundationModelDeviceTests` already covers the real model.

## Build and run

The project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen).
The generated `.xcodeproj` is committed, so opening it only needs Xcode. XcodeGen is needed only
to change the project:

```bash
xcodegen generate
```

**macOS** (this Mac, macOS 26.4+):

```bash
xcodebuild -project LocalAgentDemo.xcodeproj -scheme LocalAgentDemo -destination 'platform=macOS' -derivedDataPath .build CODE_SIGN_IDENTITY=- build
open .build/Build/Products/Debug/LocalAgentDemo.app
```

**iPhone** (iOS 26.4+, Apple Intelligence on, phone unlocked). No team ID is committed; pass yours:

```bash
xcodebuild -project LocalAgentDemo.xcodeproj -scheme LocalAgentDemo -destination 'id=<device-udid>' -derivedDataPath .build-ios DEVELOPMENT_TEAM=<team-id> -allowProvisioningUpdates build
```

**UIKit check** (iOS Simulator is enough — it doesn't need the on-device model):

```bash
xcodebuild -project LocalAgentDemo.xcodeproj -scheme LocalAgentDemoUIKitCheck -destination 'generic/platform=iOS Simulator' -derivedDataPath .build-uikit CODE_SIGN_IDENTITY=- build
```

## Planner regression tests

```bash
swift test --package-path Examples/LocalAgentDemo
```

This small Swift package compiles the actual `AgentSetup.swift` used by the app.
Tests drive `DemoPlanner` through the runtime using scripted models and fixture
tools, without calendar access, model assets or note writes. CI runs these tests;
they verify bounded execution, not real-model retrieval quality.

## Conversation resume

The app restores recent completed turns from its dedicated local Application Support
`LocalAgentDemo/conversation.store` using a stable app-owned conversation identity.
It saves after each successful run has recorded history, and disables new sends
until that save finishes. A save failure keeps the answer visible and shows an error;
it never retries the tool action. Store-opening failures surface at startup without
silently deleting the previous conversation. The existing `notes.json` is separate.

This is bounded conversation memory, not an unlimited chat archive. Older turns may
be pruned into a summary retained as model context rather than displayed as chat
bubbles. Failed or partial turns, tool activity, audit logs and pending approvals
are not restored. Restart never replays a goal or resumes a pending write. Saving a
restored checklist still requires fresh approval. Wait until “Saving conversation…”
finishes before terminating the app; an interrupted save may leave the previous
completed checkpoint. Uninstalling the app removes its local data.

Regression tests cover restored model context and displayed turns, ordered saving,
save failures, corrupt-store preservation and fresh approval for restored checklists.
See `docs/demo-conversation-resume.md` for native restart verification and limits.

## Ask a user-selected PDF (M3-10, acceptance pending)

The main chat now has **Ask a PDF**. Choose a downloaded English PDF with a text
layer, wait for indexing, then ask a specific question with a known answer. Expand
**Retrieved PDF passages** to inspect the source excerpts. `[1]` labels refer to
retrieved passages, not PDF page numbers. Verify the answer against the original;
a fluent answer or high similarity score does not establish factual support.

This is a separate, ephemeral session, with an isolated in-memory vector store and
conversation. It searches only the selected PDF, not the fixture notes, calendar,
saved notes or a previous PDF. Replacing even a same-named file resets chat identity.
Closing or cancelling clears the demo's session references and requests cancellation;
native/uncooperative work already underway may retain memory until it returns. The
demo does not checkpoint PDF turns, copy the source file to its note store or persist
PDF vectors. This is not a secure-erasure/OS-cache/screenshot guarantee.

The file picker can access provider-backed locations and the system/provider may
download selected cloud content. The screen says so; `.never` governs configured
SDK components, not the system file provider. Security-scoped access is balanced
around extraction. Indexing uses `IngestionJob` off the UI actor, shows committed
passage counts, and can be cancelled. It cannot forcibly interrupt PDFKit parsing.
A cancelled or failed import never leaves a new ready-to-query session, and a late
old import cannot overwrite a newer selection.

Demo-specific extraction limits are 8 MiB, 100 pages and 200,000 Swift characters.
Blank/image-only, locked/copy-restricted, unreadable and over-limit inputs fail visibly.
Passwords/OCR are not offered by this UI. Indexing failure (including missing local
embedding assets) is shown instead of falsely reporting readiness.

Each question uses a deterministic workflow: one `search_documents` call with the
literal query, followed by one tool-free answer request. No write tools are registered
in the PDF runtime. Empty retrieval finishes without a model call; nonempty but
irrelevant passages are still possible. Three passages are selected from twenty
candidates with whitespace deduplication and no calibrated score threshold; existing
context budgeting fits every answer request. Native guardrail refusals remain terminal.
Follow-ups can use in-session history, but the literal current query drives search;
short references such as “why?” may retrieve poorly.

This prototype uses the existing NaturalLanguage embedding path, including its
asset-dependent word-vector fallback. Decision 0009 measured substantial quality
limitations. M3-11's opt-in MiniLM/Core AI adapter is **not integrated**, M3-07's
held-out calibration is still pending, and this UI does not claim either is complete.
M3-10 and the RAG milestone exit stay open until real user-PDF acceptance is verified.

The demo test package now has eleven PDF-specific test functions (23 total), covering
real generated PDF extraction/answer context, bounded search/model-call counts,
no-evidence behavior, import limits, failures, cancellation, stale completion and
same-filename chat replacement. They use mock embeddings/models, not an on-device
answer-quality measurement. The picker and scope APIs were checked in the installed
SDK before use; macOS/iOS builds compile the actual UI. Device build/install success
alone does not verify picker interaction, answer correctness or lifecycle behavior.
