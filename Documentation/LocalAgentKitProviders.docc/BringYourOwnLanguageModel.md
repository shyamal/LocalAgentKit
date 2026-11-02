# Bring your own LanguageModel

Use an app-owned Foundation Models LanguageModel conformance with the agent runtime on OS 27.

## Construct the adapter

```swift
import FoundationModels
import LocalAgentKitCore
import LocalAgentKitProviders
import LocalAgentKitRuntime

@available(macOS 27, iOS 27, *)
func makeAgent<Model: LanguageModel>(
  model: Model, requiresNetwork: Bool, windowTokens: Int?
) throws -> AgentRuntime {
  let provider = try LanguageModelProvider(
    model: model, requiresNetwork: requiresNetwork,
    contextWindowTokens: windowTokens)
  return try AgentRuntime(
    configuration: AgentConfiguration(model: provider),
    tools: StaticToolSource([]))
}
```

The app implements or imports its model and executor; the SDK does not include
MLX, weights or another inference runtime. Core and Runtime continue to depend on
`LocalModelProvider`, not Apple's protocol. The original `FoundationModelProvider`
remains the system-model adapter on the package's iOS/macOS 26.4 floor.

Declare `requiresNetwork` explicitly, including network use by a supplied token
counter. The default agent network policy is `.never`, so network-backed models
are rejected at runtime construction. Use `.allowed` deliberately for a network
backend; the adapter does not infer locality from the model's Swift type.

## Context and token metadata

The OS 27 `LanguageModel` protocol exposes capabilities and executor configuration,
but no generic context-size or tokenizer API. Supply the actual backend window;
non-positive supplied sizes are rejected. Nil leaves the runtime's configured
fallback window in use and does not assert that the backend has a 4096-token window.

The optional `tokenCounter` closure receives the rendered `[Transcript.Entry]`,
including tool definitions and the current prompt. Return the backend's whole-input
count, or nil when unavailable. The callback should return promptly and honor
cancellation. No counter means the budgeter uses its existing estimate. The system
adapter still uses the real SystemLanguageModel token counter.

## Generation, tools and streaming

Both adapters share transcript rendering, schema translation, capture-and-hand-back
tools, error mapping, bounded malformed-output retries and append-only streaming.
Every generation gets a fresh session. The generic model must advertise tool-calling
capability when the request declares tools; a text-only model can still answer
tool-free requests. Built-in agent planners consult synthetic tools, so they require
a tool-capable backend even for their planning decisions.

The framework sees recording tools, not executable AgentTools. A requested tool
call returns to the runtime for validation and human confirmation. Native policy
refusals are terminal; context overflow is a distinct typed error. Set
`enableStreaming: true` only for backends emitting append-only text snapshots.
Generic executors may replace earlier text segments, so this adapter defaults to
final responses without fragments. The system-model adapter's streaming remains
enabled. Opted-in streaming uses the existing response-channel protection.

## Ownership and lifecycle

Provider copies share one immutable model holder under ARC. Reuse one provider
across agents rather than constructing separate heavyweight model instances.
The conformance should keep heavyweight resources in its shared backend/executor;
the framework passes model values into sessions and executor calls.

Adapter construction creates no session or executor. `prewarm()` explicitly asks
the framework to prepare a fresh session; generation otherwise creates sessions
on demand. Backend weight loading, executor caching, cancellation-aware in-flight
ownership and eviction remain the backend's responsibility. The adapter releases
its own references normally, but cannot force the framework or another app owner
to release theirs. Apple's generic protocols expose no unload method, and this
implementation does not claim measured unloading or private-weight memory limits.
M1-PR-04 remains partial for that backend lifecycle work.

## Verification

The custom-executor suite is gated on OS 27 and needs no Apple model assets or
network. It runs the real Foundation Models session pipeline with fixture executors,
including native tool calls, streaming, error mapping and runtime permission checks.
Its source is `Tests/LocalAgentKitProvidersTests/LanguageModelProviderTests.swift`.
On older hosts these tests are skipped; they can run on an OS 27 simulator even
though the system on-device model itself is unsupported there.

For a repeatable local simulator run, install XcodeGen and an OS 27 simulator runtime,
list available destinations with `xcrun simctl list devices available`, then run:

```bash
python3 Scripts/check-language-model-adapter.py --destination 'platform=iOS Simulator,id=<OS-27-simulator-UDID>'
```

The helper generates a temporary test project, references the checked-in tests and
retains derived data and xcresult logs under `.build/language-model-adapter`.
It does not install runtimes or edit the demo project. Initial package resolution
may use the network during the build; the fixture tests themselves use no service.

These tests establish adapter mechanics, not MLX integration, real custom-model
quality, physical-iPhone performance or backend eviction behavior.
