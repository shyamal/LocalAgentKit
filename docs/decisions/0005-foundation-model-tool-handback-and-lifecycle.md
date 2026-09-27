# 0005: Foundation Models tool calls are handed back by a recording tool; the system model's lifecycle is the OS's

**Status:** Accepted, 2026-09-27 — resolves PLANNING §6 open question 6
**Relates to:** PRD FR-004, FR-005, R3, NFR memory, §19; decision 0004; tasks M1-PR-01, M1-PR-02, M1-PR-03, M1-PR-04; findings §9a, §10a, §12

## Context

Two things about Foundation Models decide how `FoundationModelProvider` can be built, and neither was settled by Phase 0.

**Who runs the tools.** The framework runs its whole tool loop inside one `respond()` (findings §12): it calls the tool, feeds the result back, and returns only the final text. LocalAgentKit's security model needs the opposite. The runtime must receive the call so it can validate arguments, put the call through the permission gate, and execute it (PRD §19). If the framework executed tools itself, a schema-valid call produced by injected text would run before the gate ever saw it.

**Whose lifecycle.** PLANNING §6 question 6 asked for a shared, reference-counted provider so several agents in one app do not each hold a model in memory.

## Decision

**1. Tools given to the framework record the call and throw.** `CapturingTool` (`Sources/LocalAgentKitProviders/FoundationModel/ToolBridge.swift`) stores the call's name and arguments, then throws a sentinel. The framework wraps a tool's thrown error in `LanguageModelSession.ToolCallError`, so `respond()` ends and the provider returns the recorded call as `.toolCall` or `.multipleToolCalls`. The runtime then does everything else. A model that answers without calling a tool returns `.text`.

**2. A session is built per request and never reused.** The runtime owns the conversation; the provider renders it into a fresh `Transcript` each time. This is the pattern findings §9a verified safe on both OS versions, and it makes cancellation safe by construction.

**3. The system model has no lifecycle for us to manage.** Nothing in `FoundationModels.swiftinterface` unloads, evicts, or releases the model (searched for unload, evict, release, purge, deallocate, memory pressure: no matches). `SystemLanguageModel.default` is a system-managed, shared, `Sendable` instance, so sharing across agents is already true by construction. `FoundationModelProvider.prewarm()` provides lazy loading. **A reference-counted provider is not built for the system model.** It is reserved for bring-your-own models, where the app really does hold the memory (M1-PR-06).

## Evidence

- **Capture and throw, real model, macOS 26.6.2** (scratch experiment, then the device tests): the model called the tool with `{"query": "budget review"}`; `respond()` threw `ToolCallError` whose `underlyingError` was the sentinel; the call was captured intact; a second `respond()` on the same session afterwards answered normally.
- **Through the provider, real model:** `FoundationModelDeviceTests` (9 tests, gated by `LOCALAGENTKIT_DEVICE_TESTS=1`, green on three consecutive runs) hand a call back without executing it, return a closed choice as a schema-valid enum, accept a history containing a tool round trip, count real tokens with tool definitions included, produce a typed `.guardrailRefusal` carrying the model's own explanation, survive an abandoned request followed by a new one, and run a whole `AgentRuntime` loop.

## Consequences

- **The permission gate cannot be bypassed by the framework.** No tool the model can see has an implementation that does anything but record.
- **The model sees the real tool definitions,** so what Phase 0 measured (native tool calling, 51–63% single-call accuracy) is what the provider uses. A structured-decision schema alternative was not adopted, because it is unmeasured.
- **Parallel calls are returned in arrival order,** which the framework does not define. Callers must not depend on it.
- **A request that ends with a tool result cannot be continued as such:** there is no "continue" call, so trailing results are folded into the prompt as text (`TranscriptRenderer`). Orphaned outputs and dangling calls are never passed through, since iOS 27 rejects them (findings §10a).
- **Unverified here:** every code path that needs OS 27 (`LanguageModelError` mapping, `GeneratedContent.ParsingError`) compiles but has not run, because this host is macOS 26.6.2. The iOS 27 simulator or a macOS 27 host is needed to exercise them.
- **`AgentTool` vs Apple's `Tool` (PLANNING question 8)** is answered in practice: `AgentTool` stays LocalAgentKit's type, and `CapturingTool` is the only bridge to Apple's, one way, for definitions.
