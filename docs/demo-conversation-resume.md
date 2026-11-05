# Demo conversation resume (M2-14)

Verified 2026-11-05 on Apple silicon with Xcode 27.2 and Swift 6.4.2.

## Behavior and ownership

`DemoConversationSession` in the actual app setup restores a stable UUID from
Application Support/LocalAgentDemo/conversation.store before constructing the
runtime and its display. The SwiftData conversation schema is separate from
notes.json and generic durable memory. No runtime-default persistence is enabled.

The optional AgentViewModel completion hook awaits successful runtime.run return,
including history recording, before checkpointing. A completed event alone is too
early. New sends stay disabled while bookkeeping and the hook finish. Hook errors
retain the answer and surface through lastFailure without replaying any action.
The finishing state reflects host work after existing terminal runtime events,
not a new engine state. The app guards startup against duplicate session owners.

Restored user/assistant pairs populate the UI and restored memory supplies the next
budgeted prompt. This is recent, bounded memory: older content may be summarized
or pruned, and leading system summaries remain model context, not chat bubbles.
Failures, refusals, partial output, task facts, tool activity, audit rows and pending
approvals are not restored. An interrupted save can leave the previous checkpoint.
Bad stores fail closed without automatic reset. Uninstall removes local app data.

## Automated evidence

- Root suite: 635 test functions pass, including three new completion-hook
  functions (one parameterized over failure/refusal/cancellation). They check
  history ordering, send serialization, failure visibility and later recovery.
- Demo suite: 12 declared functions, with the synthetic fixture helper disabled
  by default. Four new integration functions cover reopened history reaching UI
  and prompt, failed-turn checkpoint preservation, fresh approval/denial and exact
  restored checklist saving, and corrupt-file preservation.
- Offline suite, four custom-tool functions, strict Swift formatting, layering,
  31 Python tests and DocC validation pass. Core/Runtime line coverage is 98.72%
  (2632/2666), above 80%; Core 99.17%, Runtime 98.56%. Combined coverage is 0.04
  percentage points below the preceding run (one fewer executed Runtime line),
  with no Core/Runtime source changes in this task.
- The three completion-hook functions also pass under Thread Sanitizer.
- Swift package build is warning-free. Both macOS and iOS Simulator demo builds
  succeed. Xcode emits its existing no-AppIntents metadata-extraction warning;
  the macOS destination selector also reports multiple matching destinations.

## Native cold-launch check

The actual iOS app was built with the isolated bundle identifier
`dev.localagentkit.demo.resumecheck`, installed on a disposable iPhone 17 Pro / iOS
26.5 simulator, and seeded with a synthetic completed conversation using:

```bash
LOCALAGENTKIT_DEMO_RESUME_FIXTURE_DIR=/private/tmp/lak-demo-resume-fixture \
  swift test --package-path Examples/LocalAgentDemo --filter optionalNativeSmokeFixture
```

After the fixture writer exited, its conversation.store files were copied to only
that isolated bundle's Application Support/LocalAgentDemo directory. Two separate
cold launches (PIDs 46429 and 46548), with termination between them, both displayed:

- User: Create a preparation checklist.
- Assistant: Resume verification checklist / - Synthetic Budget review preparation.

Both screenshots were visually inspected. No old tool activity or approval was
shown. No actual user data was seeded or changed. The disposable simulator was
removed after verification. This native check demonstrates startup/display restore;
automated integration tests separately verify successful-run autosave and reuse.
It does not measure real Foundation Models generation in Simulator or claim a new
physical-iPhone acceptance run. Test the four-turn flow on a real device for that.

## Reproduce the regular checks

```bash
swift build
bash Scripts/check-coverage.sh
bash Scripts/check-offline-tests.sh
swift test --package-path Examples/CustomTool
swift test --package-path Examples/LocalAgentDemo
xcrun swift-format lint --configuration .swift-format --strict --recursive Sources Tests Package.swift
bash Scripts/check-layering.sh
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
python3 Scripts/build-docs.py
python3 Scripts/check-docs.py .build/documentation/LocalAgentKit.doccarchive
```

Physical-device permissions, model quality and independent developer validation
remain separate from this persistence check.
