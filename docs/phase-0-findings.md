# Phase 0 Findings

**Status:** In progress. This document accumulates verified findings as Phase 0 runs, per task P0-16 — it is not written only at the end. Everything below is either a direct reading of the shipping SDK or the output of a real program run on this machine, not a claim from memory or documentation.

**Environment:** Apple silicon Mac, host macOS **26.6.2**, Apple Intelligence **enabled** (`SystemLanguageModel.default.availability == .available` — see finding 5).

Two toolchains now installed side by side, which is what unblocked findings 1–2 (and closes task M0-16):

| | Xcode | Build | Swift | macOS SDK | Notes |
|---|---|---|---|---|---|
| Release | 26.6 | 17F113 | 6.3.3 | `MacOSX26.5.sdk` | what findings 3–7 were measured against |
| **Beta** | **27.0** | **27A5252f** | **6.4** | **`MacOSX27.0.sdk`** | + `iPhoneOS27.0.sdk`, iOS 27.0 simulator runtime (24A5423a) |

**Update 2026-09-18:** `Xcode.app` auto-updated on 2026-09-15 to **Xcode 27.0 release (27A266a, Swift 6.4, `MacOSX27.0.sdk`)**, so the "Release 26.6" row above no longer describes the default toolchain. The table is kept as the record of what findings 1–7 were measured against. The GA `FoundationModels.swiftinterface` is **identical to the beta's**, apart from the compiler-version header (`diff` shows 0 lines), and `CoreAI.framework` ships in GA too, so findings 1–2 now describe a **shipping** SDK. The host OS is still macOS 26.6.2.

The package builds warning-free and its tests pass under **both** toolchains (M0-16). Findings dated 2026-09-10 come from the beta SDK; findings dated 2026-09-02 come from the release SDK and say so where it matters.

**Reading note:** the beta SDK is installed but the beta **OS** is not. A macOS 27 binary cannot run on this host, so macOS-side beta findings are *static* (interface + compile) unless stated otherwise; the iOS 27 simulator is available and is what runtime claims below are executed on.

---

## 1. `CoreAI.framework` — **EXISTS in the beta SDK**, but it is a tensor runtime, not the LLM abstraction

**RESOLVED 2026-09-10** against Xcode 27.0 beta (build 27A5252f, Swift 6.4), `MacOSX27.0.sdk`. Supersedes the 2026-09-02 release-SDK-only finding, which is preserved at the end of this section.

```
$ ls MacOSX27.0.sdk/System/Library/Frameworks/ | grep -i "coreml\|coreai"
CoreAI.framework
CoreML.framework
```

`CoreAI.framework` **is present**, plus six SubFrameworks: `CoreAIRuntime`, `CoreAICompiler`, `CoreAICommon`, `CoreAIAsset`, `CoreAICache`, `CoreAIDelegates`. Availability is `@available(macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0, *)` — beta-only, which is exactly why the release-SDK check found nothing. **The user was right and the PRD's premise was directionally correct**; the 2026-09-02 finding was scoped accurately but was reading an SDK that predates the framework.

**But the shape is not what the PRD implies.** `CoreAI.framework` itself is a 9-line umbrella that only re-exports `CoreAIDelegates`. The real surface is `CoreAIRuntime` (1428 lines), and its public types are a low-level tensor/inference API:

```
AIModel  InferenceFunction  InferenceFunctionDescriptor  NDArray  NDArrayDescriptor
ComputeStream  Inputs  Outputs  View / MutableView / RawView  ImageDescriptor  ScalarType
```

`AIModel` exposes `functionNames: [String]` and `functionDescriptor(for:) -> InferenceFunctionDescriptor?`. This is a "load a compiled model, bind NDArray inputs, run named inference functions" runtime — a Core ML successor in *role*, not an LLM or agent API.

Two corrections to the PRD's framing follow:
- **Core ML is not "replaced."** `CoreML.framework` still ships in the beta SDK alongside `CoreAI.framework`. PRD §1/R5's "Core AI has replaced Core ML" overstates it — for macOS 27 they coexist.
- **Core AI is not the path to a custom LLM provider.** The BYO-LLM mechanism lives in Foundation Models, not here — see finding 2. A `CoreAIModelProvider` (FR-004) built on `CoreAIRuntime` would mean hand-rolling tokenization, KV-cache, and sampling on top of NDArrays. That is not what FR-004 wants; finding 2's protocol is.

<details>
<summary>Original 2026-09-02 release-SDK finding (superseded, kept for the record)</summary>

Searched Xcode 26.6 / `MacOSX26.5.sdk`: `CoreML.framework` present, zero matches for "CoreAI" anywhere in the SDK tree. Correctly scoped at the time as "absent from the current release SDK," explicitly *not* a verdict that Core AI does not exist. The beta check above is the resolution it was waiting on.
</details>

## 2. Foundation Models **DOES accept third-party model providers** — via `LanguageModel` + `LanguageModelExecutor`

**RESOLVED 2026-09-10 — verified by compiling *and running* a non-Apple model through the stock session.** This reverses the tentative direction of the 2026-09-02 finding.

The earlier check grepped the release `.swiftinterface` for `mlx|third.?party|custom.?llm|bring.?your|external.?model` and got zero matches. Those greps still return **zero matches against the beta interface** — the vocabulary was never Apple's. The mechanism is there under different names.

The beta `FoundationModels.swiftinterface` is **3647 lines vs. 1501 in release**. Among what is new — none of these exist in the release interface at all (verified: 0 matches each):

```swift
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public protocol LanguageModel : Sendable {
    associatedtype Executor : LanguageModelExecutor where Self == Self.Executor.Model
    var capabilities: LanguageModelCapabilities { get }
    var executorConfiguration: Self.Executor.Configuration { get }
}

public protocol LanguageModelExecutor : Sendable {
    associatedtype Configuration : Hashable, Sendable
    associatedtype Model : LanguageModel
    func prewarm(model: Self.Model, transcript: Transcript)
    init(configuration: Self.Configuration) throws
    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: Self.Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws
}
```

`SystemLanguageModel` and the also-new `PrivateCloudComputeLanguageModel` are both just conformances to this protocol. Apple abstracted its *own* models behind it — and left it public.

And `LanguageModelSession` is generic over it. Alongside the four `SystemLanguageModel`-typed convenience inits, the beta interface adds a full parallel set (lines 1947–1956):

```swift
convenience init(model: some LanguageModel, tools: [any Tool] = [], instructions: Instructions? = nil)
convenience init(model: some LanguageModel, tools: [any Tool] = [], transcript: Transcript)
convenience init<Failure>(model: some LanguageModel, tools: [any Tool] = [],
                          @InstructionsBuilder instructions: () throws(Failure) -> Instructions) throws(Failure)
convenience init(model: some LanguageModel = SystemLanguageModel.default,
                 dynamicInstructions: sending some DynamicInstructions,
                 history: some Collection<Transcript.Entry> = [])
```

So a custom model gets the whole stock session: tools, transcript, instructions, streaming, structured output.

**GA confirmation (2026-09-18):** the Xcode 27.0 *release* SDK's `FoundationModels` interface is identical to the beta's, apart from the compiler-version header, including `LanguageModel`, `LanguageModelExecutor`, and all four `init(model: some LanguageModel, …)` overloads. This is a shipping API, not a beta capability. That strengthens the case for resolving PLANNING §6 question 9, but doesn't decide it: back-deploying to macOS/iOS 26 is still the trade-off.

### Verified by execution, not by reading

A disposable spike defined `EchoModel: LanguageModel` + `EchoExecutor: LanguageModelExecutor` — no Apple weights, no `SystemLanguageModel` — and drove it through `LanguageModelSession.respond(to:)`. It compiles **warning-free under `-swift-version 6 -strict-concurrency=complete`** and, run on the **iOS 27.0 simulator** (24A5423a):

```
RESULT: [echo-v1] executor ran; transcript entries=2
TRANSCRIPT ENTRIES AFTER: 3
```

The custom executor ran, received the framework-built `Transcript` (2 entries: instructions + prompt), streamed text back via `channel.send(.response(action: .appendText(_:tokenCount:)))`, and the framework appended the result to the session transcript. **BYO-LLM works.**

One caveat, recorded honestly: the same binary built for `macos27.0` **fails to launch on this Mac** (`dyld: Symbol not found: ...LanguageModelP12capabilities...`, "built for macOS 27.0 which is newer than running OS") because the host is macOS 26.6.2. The macOS runtime path is therefore statically verified but not yet executed; the iOS 27 simulator is what supplied the runtime proof. Installing the macOS 27 beta would close that last gap.

### What an executor must actually implement

`LocalAgentKit`'s provider work should be sized against these, not guessed at:

```swift
struct LanguageModelExecutorGenerationRequest : Sendable {
    var id: UUID
    var transcript: Transcript
    var enabledToolDefinitions: [Transcript.ToolDefinition]
    var schema: GenerationSchema?          // guided generation is the executor's job
    var generationOptions: GenerationOptions
    var contextOptions: ContextOptions
    var metadata: [String : GeneratedContent]
}
```

The channel is an `AsyncSequence` you `send(_:)` into, with three event families — `.response`, `.reasoning`, `.toolCalls` — plus `.updateUsage(input:output:)` for token accounting. A model declares what it can do via `LanguageModelCapabilities([.toolCalling, .vision, .guidedGeneration, .reasoning])`, and `LanguageModelError.unsupportedCapability(_:)` is the typed failure when a session asks for more.

### Consequence for R5 and `LocalModelProvider` — a real architectural question, not yet decided

The 2026-09-02 note reasoned that *if* no BYO-LLM API existed, `LocalModelProvider` would be **more** valuable than the PRD assumed. That branch did not happen, so **that reasoning is void and the PRD's original R5 concern stands** — and is in fact sharper than the PRD put it:

`FoundationModels.LanguageModel` / `LanguageModelExecutor` *is* the model-provider abstraction `LocalModelProvider` (FR-003/FR-004) was specified to be. A LocalAgentKit-defined protocol alongside it risks being a parallel abstraction over the same seam, with a bridge in the middle earning nothing. The live options — **for the user to decide, not for this document**:

1. **Drop `LocalModelProvider`**; have LocalAgentKit consume `some LanguageModel` directly. Loses the layering rule as written (Core would need the `FoundationModels` type) and loses pre-macOS-27 support.
2. **Keep `LocalModelProvider` as the Core-level seam**, ship a thin adapter both ways. Preserves layering + metric M3 and back-deploys to macOS 26, at the cost of one indirection.
3. **Invert it**: LocalAgentKit ships `LanguageModelExecutor` conformances (llama.cpp, MLX) as its differentiator and drops model abstraction entirely, competing on tools/permissions/RAG instead.

Option 2 is the smallest change and the only one that keeps the grep-enforced layering rule and M3 intact; note that all three depend on a **macOS/iOS 27 minimum** if they touch these types at all, which is a deployment-target decision the PRD has not made. **This blocks finalizing FR-003/FR-004 and `Package.swift`'s platform floor — flagged, not resolved.**

## 3. Context size and token counting ARE exposed

**Resolves `PLANNING.md` §6 open question 2.**

```swift
extension SystemLanguageModel {
    public var contextSize: Int { get }   // returns 4096, verified at runtime on this machine
    public func tokenCount(for prompt: some PromptRepresentable) async throws -> Int
    public func tokenCount(for instructions: Instructions) async throws -> Int
    public func tokenCount(for tools: [any Tool]) async throws -> Int
    public func tokenCount(for schema: GenerationSchema) async throws -> Int
    public func tokenCount(for transcriptEntries: some Collection<Transcript.Entry>) async throws -> Int
}
```

Verified at runtime: `model.contextSize == 4096`.

**Conclusion: `ContextBudgeter` (task M1-RT-04) can budget against a real token count, not an estimate.** This removes the main risk PLANNING.md §6 question 2 raised (budgeting degrading to estimation). 4096 tokens is a small budget in absolute terms — this raises the *importance* of context budgeting (R2) even as it resolves the *feasibility* of measuring it precisely.

## 4. Guardrail refusals are structured and programmatically distinguishable

**Resolves `PLANNING.md` §6 open question 3.**

The real `LanguageModelSession.GenerationError` enum, read from the shipping interface:

```swift
public enum GenerationError: Error, LocalizedError {
    case exceededContextWindowSize(Context)
    case assetsUnavailable(Context)
    case guardrailViolation(Context)
    case unsupportedGuide(Context)
    case unsupportedLanguageOrLocale(Context)
    case decodingFailure(Context)
    case rateLimited(Context)
    case concurrentRequests(Context)
    case refusal(Refusal, Context)   // Refusal exposes an async `.explanation` from the model itself
}
```

Verified at runtime — a prompt requesting instructions for synthesizing a controlled substance threw:

```
guardrailViolation(Context(debugDescription: "May contain unsafe content", underlyingErrors: [], errorDescriptionOverride: nil))
```

**Conclusion: yes, unambiguously.** A refusal is a specific, catchable `case`, not something that has to be detected by pattern-matching the generated text. There are actually **two** distinct refusal-shaped cases — `guardrailViolation` (blocked before/during generation by a safety classifier) and `refusal` (the model itself generated a refusal, which even exposes an async `.explanation` accessor). FR-005's `.refused(GuardrailRefusal)` and FR-025's `.guardrailRefusal` should map onto both, distinguishing them if the distinction proves useful once more refusal cases are observed (P0-07/P0-11).

**Bonus finding, not in scope of any open question:** `exceededContextWindowSize(Context)` is a real, distinct error case. This maps directly onto FR-025's `.contextLimitExceeded` — the framework already surfaces this as a typed error, which simplifies `ContextBudgeter`'s job (task M1-RT-05): the runtime still needs to trim/summarize *before* hitting this, but detecting the failure itself doesn't need custom logic. `rateLimited` and `concurrentRequests` are two more real failure modes the PRD's `AgentError` enum (FR-025) doesn't currently name and should.

**Addendum 2026-09-18:** on iOS/macOS 27, `GenerationError` is deprecated. `guardrailViolation` and `refusal` move to the new `LanguageModelError` (see §9c). The conclusion stands structurally; runtime verification on 27 is pending.

## 5. Apple Intelligence is active on this development machine

Not a resolution of a numbered open question, but directly relevant to how Phase 0 gets executed: `SystemLanguageModel.default.availability` returns `.available` on this Mac (macOS target, not iOS). This means:

- Some Phase 0 measurement (P0-09 through P0-12, for the **macOS** target) can run directly on this development machine, right now — the CLAUDE.md/PLANNING.md guidance that "device work needs ... a physical Apple Intelligence-capable device" is still correct for **iOS-specific** behavior, thermals, and battery (there is no iPhone involved here), but is not a blocker for macOS-target functional measurement.
- This was itself verified by running a real Swift program (`SystemLanguageModel.default.availability`), not assumed.

## 6. A single-tool call round trip succeeds (N=1, positive signal only)

Ran a real, minimal tool-calling scenario end to end:

```swift
struct AddTool: Tool {
    let name = "add_numbers"
    let description = "Adds two integers and returns the sum."
    @Generable struct Arguments {
        @Guide(description: "The first integer") let a: Int
        @Guide(description: "The second integer") let b: Int
    }
    func call(arguments: Arguments) async throws -> String { "\(arguments.a + arguments.b)" }
}
let session = LanguageModelSession(tools: [AddTool()])
let response = try await session.respond(to: "What is 47 plus 89? Use the add_numbers tool.")
```

Transcript showed a correctly schema-valid tool call (`add_numbers: {"a": 47, "b": 89}`) and a correct final answer incorporating the tool's output. **This is one successful trial, not a measurement** — P0-09/P0-10 still need the full ~20-goal and ~10-multi-step-goal suites (P0-05, P0-06) run and tallied before any claim about R1's actual reliability rate can be made. Recorded here only as a working-mechanism proof, not evidence toward the >95% M5 target either way.

## 7. Apple's own `Tool` protocol already exists

`FoundationModels` ships its own tool-calling abstraction:

```swift
public protocol Tool<Arguments, Output>: Sendable {
    associatedtype Arguments: ConvertibleFromGeneratedContent
    associatedtype Output: PromptRepresentable
    var name: String { get }
    var description: String { get }
    func call(arguments: Arguments) async throws -> Output
}
```

This is relevant to task M1-CO-03 (`AgentTool` protocol design): `AgentTool` is not being designed in a vacuum — it needs to either wrap/bridge to this existing `Tool` protocol (so an `AgentTool` conformance can be handed to `LanguageModelSession` without a manual adapter per tool) or explicitly justify why it doesn't. `AgentTool`'s value-add over the raw `Tool` protocol is exactly the permission tier, schema-beyond-`@Generable` validation, and parallel-safety/cancellability declarations — none of which `Tool` provides. This should be designed as a wrapper, not a parallel reinvention.

---

## 8. Other beta additions that touch planned features

Not the P0-03 question, but found in the same 1501→3647-line diff and relevant enough to record before someone plans around the release surface:

| New in beta | Why it matters here |
|---|---|
| `PrivateCloudComputeLanguageModel` | An Apple-hosted, off-device model behind the *same* `LanguageModel` protocol. Directly relevant to the PRD's on-device/privacy positioning and to NFR network-policy declarations — an app can now escalate off-device through stock API, so "local" needs restating as a deliberate constraint, not an Apple limitation. |
| `ReasoningLevel`, `Reasoning`, `ReasoningSignature` | The model exposes reasoning as first-class transcript content. Affects `AgentEvent` design and the planner work (M1-RT-11/12): reasoning may be observable rather than inferred. |
| `DynamicInstructions`, `DynamicProfile` (+ result builders) | A composable instruction/profile system. Overlaps what LocalAgentKit was going to build for prompt assembly. |
| `ContextOptions`, `ContextSizeExceeded`, `LimitReached`, `QuotaUsage`, `RateLimited`, `Timeout` | More typed failure modes for FR-025's `AgentError` than the release enum offered (extends finding 4). |
| `ToolCallingMode`, `ToolCallError`, `ToolOutput`, `Transcript.ToolDefinition` | Firms up finding 7 — `AgentTool` should bridge to this, and the executor sees `enabledToolDefinitions` per request. |
| `LanguageModelFeedback` | Structured feedback channel; possible fit for the FR-029 eval harness. |

None of this is verified beyond interface reading + the finding 2 compile/run; treat as a map of what to check, not as settled API.

## 9. Session lifecycle, streaming, and structured output (P0-02) — macOS verified, iPhone pending

**2026-09-18.** From the P0-01 spike ([`Spike/`](../Spike/)), on this Mac, **macOS 26.6.2** (the only OS 26 host available). Each check was run 1–3 times, so these results describe how the API *behaves*. They are not rates. The physical-iPhone half (iPhone 15 Pro, iOS 27.0 24A435) is built and waiting on device provisioning; see "Not yet done".

| Check | macOS 26.6.2 result |
|---|---|
| Availability | `.available`, `contextSize` 4096, current locale supported, 23 languages |
| Latency, 1-word reply (N=3) | Warm calls 190–340 ms. The **first call in a process** takes 0.56–1.4 s. At N=3, prewarm made no measurable difference; P0-14 owns latency properly |
| Multi-turn reuse | Pass. A fact stated in turn 1 is recalled in turn 2. Two turns = 5 transcript entries (instructions + 2×prompt/response) = 80 tokens |
| Transcript restore via `Codable` | Pass. `Transcript` is `Codable` (1.4 KB for two turns), and a new session built from the decoded copy recalls the fact. **Conversation persistence across launches (M2-04) can store the framework's own transcript** |
| Concurrent request | The second `respond` on a busy session throws a typed `concurrentRequests`, and the first request still completes. **The runtime must serialize requests per session** |
| Text streaming | Snapshots are **cumulative** (each one is the full text so far, not a delta): 12 snapshots over 2.0 s, first at ~350 ms |
| `@Generable` output | Pass. A nested struct, an enum, `.range` and `.count` guides were all respected (7 days, 3 stops, nights sum to 7) |
| `@Generable` streaming | Properties fill in order, and arrays grow one element at a time: the stop count went `[0,1,2,3]` over 6 snapshots |
| Runtime schema (`DynamicGenerationSchema`) | Pass with an **unanchored** pattern guide, which produced exactly `2026-09-22T09:00` |
| `Response.usage` | Only on 27; not observable on macOS 26 |

### 9a. Abandoning a stream, then reusing the session, crashes the process 🔴

This is the most consequential P0-02 result, because it constrains how the runtime implements cancellation (NFR "support cancellation", `AgentTool.isCancellable`).

- **The crash.** Stop consuming a `streamResponse` (by `Task.cancel()` or by `break`), then send the next request on the *same* session immediately. The process dies inside FoundationModels: **3/3 SIGTRAP or SIGSEGV** with `EXC_BREAKPOINT` in a FoundationModels frame on a concurrency thread, and nothing on stderr. A *fresh* session passes 3/3; the same session after 100–1000 ms passes 6/6.
- **Why.** Sampling the transcript after abandonment showed the same pattern 6/6: at t=0 it still holds `[prompt,response]`; **by t=25 ms the framework has rolled the abandoned exchange back out, to `[]`**, and `isResponding` already reads `false` at t=0. So `isResponding` goes false before the rollback finishes, and a request that lands mid-rollback crashes. The delay "fix" is timing luck, not a guarantee.
- **The transcript is contaminated in the meantime.** A copy of `session.transcript` taken in that window contains the abandoned prompt. A session rebuilt from it answered the *abandoned* prompt instead of the new one in 2 of 3 runs.
- **Cancellation doesn't throw.** `Task.cancel()` ends the stream's `for try await` loop **normally**: no `CancellationError`, `completedNormally` 3/3. Code that detects cancellation by catching the error will never see it.
- **The safe pattern, verified 3/3:** snapshot `session.transcript` **before** starting a stream; after abandoning it, **discard the session and rebuild from the snapshot**. This doesn't depend on timing.

**What this means for Milestone 1 (not yet acted on):** `AgentRuntime` should own its transcript and treat a `LanguageModelSession` as disposable after any abandoned request. It should track cancellation itself rather than infer it from errors, and never gate the next request on `isResponding`. iOS/macOS 27 adds a typed `LanguageModelSession.Error.transcriptMutationWhileResponding`, which may be how 27 reports this same race. **Whether 27 still crashes is the first thing the iPhone run must answer** (`--only cancellation-break --same-session`).

### 9b. Anchored regex guides are rejected, with an untyped error

A `GenerationGuide.pattern` written with `^…$` is refused **4/4**, both optional and required. The error is untyped: an `NSError` (domain `LanguageModelSession.GenerationError`, code −1) wrapping `GenerativeError` 1020000, with no message. It does **not** arrive as a typed `GenerationError` case. The same pattern without anchors works, and the output still matches the whole value. With no pattern at all, the model wrote `2026-09-22T09:00:00` (right time, wrong format), so the guides do real work.

Consequences, already applied: `EvalSuites/phase0/tools.json` had three anchored patterns that would have failed every datetime goal at run time. They're now unanchored, the file states the rule, and the validator rejects anchors. For FR-025: `AgentError` mapping must handle untyped framework `NSError`s, not only the typed enums. iOS 27 adds `LanguageModelError.unsupportedGenerationGuide`, so this may be typed there; unverified.

### 9c. OS 27 replaces the error types that P0-13 relied on

Building the spike for iOS 27 failed on a deprecation: **`LanguageModelSession.GenerationError` is deprecated in iOS/macOS 27.** It's split into:

- `LanguageModelError` (model outcomes): `contextSizeExceeded`, `rateLimited`, `guardrailViolation`, `refusal`, `unsupportedCapability`, `unsupportedTranscriptContent`, `unsupportedGenerationGuide`, `unsupportedLanguageOrLocale`, `timeout`
- `LanguageModelSession.Error` (session misuse): `concurrentRequests`, `transcriptMutationWhileResponding`

**P0-13's conclusion still holds on 27, structurally:** `guardrailViolation` and `refusal` remain distinct typed cases. But the *type* a provider must catch differs by OS version, and on 27 it hasn't been triggered at runtime yet. `FoundationModelProvider` (M1-PR-03, `.refused`) must map both generations of error types, which is one more input to the deployment-floor decision in PLANNING §6 question 9.

### Unrelated system noise, recorded so nobody chases it

`intelligencetasksd` was crash-looping on this Mac, with launchd backoff doubling from 10 s, **starting at 19:23, 14 minutes before the first spike run**. Model calls were unaffected throughout. It's not caused by the spike.

## Not yet done

Findings 1–2 are now resolved against the beta SDK; **the measurement half of Phase 0 has still not started.** Everything above is static SDK inspection plus small compile/run spikes (in scratch packages, not committed) — it is **not** a substitute for P0-01 through P0-14 as scoped:

- **P0-01 is committed** as [`Spike/`](../Spike/) (2026-09-18): an Xcode app for iOS 27 and macOS 26.4+ that compiles warning-free for both and runs on this Mac. The finding-2 BYO-LLM spike is still uncommitted scratch code.
- **P0-02 on the physical iPhone is pending**: the app is built, but a free Personal Team needs the phone unlocked once so Xcode can register it and create a provisioning profile, and the developer must then be trusted on the phone. Until it runs, every §9 result is **macOS 26.6.2 only**. On OS 27 the error types differ (§9c), and whether the §9a crash persists is unknown.
- P0-05 and P0-06 are written (`EvalSuites/phase0/single-tool.json`, 20 goals; `multi-step.json`, 10 goals; both 2026-09-18) but **not yet run**. P0-07 (the 20-goal refusal suite) and P0-08 (context-load fixture) have not been written.
- P0-09–P0-12 (the measured rates: tool-call validity, multi-step completion, refusal rate, context exhaustion) have not been produced — finding 6 is one trial, not a rate.
- **P0-15 (the planner GO/NO-GO) therefore cannot be called**, since it depends on P0-09/P0-10. Milestone 1 remains gated. 🔒
- P0-14 (latency/thermal/battery) has not been attempted — and still needs a *physical* Apple Intelligence device; neither this Mac nor a simulator can measure iPhone thermals.
- The `GenerationError.refusal` case (model-generated refusal, as distinct from `guardrailViolation`) has not been triggered or inspected at runtime.
- **New, from finding 2:** the `LocalModelProvider` / `LanguageModel` overlap and the resulting **macOS/iOS 27 deployment-floor decision** are open and block finalizing FR-003/FR-004 and `Package.swift`. This is a design call for the user.
- **New, from finding 1:** FR-004's `CoreAIModelProvider` should be re-specified or dropped — `CoreAIRuntime` is a tensor API, not a text-generation one.
- Runtime verification on **macOS** 27 awaits the beta OS; the beta *SDK* is installed, the beta *OS* is not.
