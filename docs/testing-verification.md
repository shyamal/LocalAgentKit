# Milestone 1 testing verification

Verified 2026-10-10 on the installed Xcode toolchain. Phase 0 has reported; the
state-machine planner remains the default. This audit closes M1-TS-02 through
M1-TS-05, not the remaining Milestone 1 implementation tasks or its device-demo exit.

## Unit coverage map

| Contract | Test suites / files under Tests |
|---|---|
| Runtime events, limits, retries, cancellation, suspension | LocalAgentKitRuntimeTests/AgentRuntimeTests.swift |
| Planner decisions, bindings, guards, recovery | LocalAgentKitRuntimeTests/StateMachinePlannerTests.swift |
| Registry and schema rejection | LocalAgentKitToolsTests/ToolRegistryTests.swift; LocalAgentKitCoreTests/ToolSchemaTests.swift |
| Validation before gate before execution | LocalAgentKitRuntimeTests/ToolExecutorTests.swift |
| Budget shares, trimming, summarization, overflow | LocalAgentKitRuntimeTests/ContextBudgeterTests.swift |
| Repeated-call cycles | LocalAgentKitRuntimeTests/LoopDetectorTests.swift |
| Permission tiers and injected document calls | LocalAgentKitRuntimeTests/PermissionManagerTests.swift; PromptInjectionDefenseTests.swift |
| Cross-run history and retrieval | LocalAgentKitRuntimeTests/AgentRuntimeMemoryTests.swift; RetrievalWiringTests.swift |
| Goal execution contracts | LocalAgentKitRuntimeTests/AgentScenarioTests.swift |

The new parameterized scenarios exercise read-only calendar and document search,
approved note creation, denied note creation, and denied destructive deletion.
They assert requested versus completed tools, exact successful results or typed
permission denial, execution limits, gate consultations, and script consumption.
A separate four-turn scenario checks earlier meetings and notes reach checklist
reasoning, the checklist reaches the save prompt, and saving waits for confirmation.
All use deterministic stand-ins; they do not score language-model quality or verify
SwiftUI rendering. The FR-029 reliability harness remains M1-EV-01 through M1-EV-08.

## Reproduce

```bash
swift build
bash Scripts/check-coverage.sh
xcrun swift-format lint --configuration .swift-format --recursive --strict Sources Tests Package.swift
bash Scripts/check-layering.sh
bash Scripts/check-offline-tests.sh
```

Coverage: Core **99.32%** (436/439 lines), Runtime **97.94%** (1471/1502),
combined **98.25%** (1907/1941), above the 80% gate. The collector reads all current
SwiftPM test bundles and unions hits by source file and line. The default suite
passed: Tools 56 tests, Testing 15, SwiftUI 14, Runtime 178, Providers 53
(including disabled integration tests), Eval 7, Core 42. Parameterized cases are
reported separately within their test function.

The offline script runs the already-built default suite with socket networking
denied to its process and children, and clears the device-test opt-in. SwiftPM's
inner manifest sandbox is disabled because macOS cannot nest it inside this outer
sandbox; the outer network-denial policy remains active. Compilation/dependency
resolution occurs before this check. It does not constrain pre-existing system
services or prove the product-wide traffic-capture metric M10.

Real Foundation Models generation and linguistic embedding tests are disabled by
default because installed model assets are not guaranteed. Run them explicitly
on a supported host with the assets available:

```bash
LOCALAGENTKIT_DEVICE_TESTS=1 swift test --filter FoundationModelDevice
LOCALAGENTKIT_DEVICE_TESTS=1 swift test --filter NLEmbeddingProviderTests
```

Pure word-averaging fallback tests stay in the default suite. Real-model integration
checks were not run for this mock-based testing change. The iPhone tester confirmed
turn 2 found notes; turns 3 and 4 still need physical-device confirmation.
