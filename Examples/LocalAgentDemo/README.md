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
code computes tomorrow in the runtime timezone, reads once, then asks the model
to answer from that observation. This also handles an empty calendar. Other wording
and subsequent turns use `StateMachinePlanner` open mode. Single-call tool accuracy measured 51–63% in Phase 0
(`docs/phase-0-findings.md` §11); a real run may need the argument-repair path, or may occasionally
pick the wrong tool. That's the honest, measured state of R1, not a demo bug.

For the physical-device milestone exit check, follow
[Device validation](DEVICE-VALIDATION.md). It covers conversation continuity,
confirmation before saving, stored-note verification and denial.

## `CreateNoteTool`

This is a minimal, MVP-only note-saving tool (`Sources/LocalAgentKitTools/CreateNoteTool.swift`),
narrower than FR-008's full Notes capability (M2-09: create *and* search, likely SwiftData-backed
like `MemoryStore`'s other implementations). It exists so this demo's fourth turn has something
real to write to, file-backed under Application Support; M2-09 supersedes it.

Successful note saves also display the actual `create_note` tool result with a
checkmark, independently of the model's final wording. Approval alone does not
show success; the tool must complete without an empty result.

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
