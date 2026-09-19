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

## 9. Session lifecycle, streaming, and structured output (P0-02): Mac and physical iPhone

**2026-09-18.** From the P0-01 spike ([`Spike/`](../Spike/)), run on two hosts:

- **Mac:** macOS 26.6.2
- **iPhone:** a physical **iPhone 15 Pro (iPhone16,1), iOS 27.0 (24A435)**, Apple Intelligence on

Each check ran 1–3 times per host (the targeted repros ran more, as noted below). So these results describe how the API *behaves*; they are not rates. The two hosts differ in **both** platform and OS version, so a difference between the columns can't be pinned on either one alone.

| Check | macOS 26.6.2 | iPhone 15 Pro, iOS 27.0 |
|---|---|---|
| Availability | `.available`, `contextSize` 4096, 23 languages | `.available`, `contextSize` 4096, 24 languages |
| Latency, 1-word reply (N=3) | 190–340 ms warm; the first call in a process takes 0.56–1.4 s | **740–880 ms warm; the first call takes 2.1 s**. Roughly 3–4× the Mac |
| Prewarm | No measurable effect at N=3 | No measurable effect at N=3 (882/884/884 ms vs. cold 743–831 ms) |
| Multi-turn reuse | Pass. Turn-2 answer recalls the turn-1 fact | Pass |
| Transcript tokens after 2 turns | 80 | 107. **Corrected 2026-09-19:** this is not a general tokenizer difference. For identical content, totals agree within ~2% across the two OS versions (§10), and the gap sits mainly in how instructions are counted (161 vs. 129 for the fixture's instructions) |
| `Response.usage` | Not available (27+ only) | Turn 2: 103 input, 9 output tokens |
| Transcript restore via `Codable` | Pass, 1.4 KB | Pass, 2.1 KB |
| Concurrent request | Throws typed `GenerationError.concurrentRequests`; the first request completes | Throws typed **`LanguageModelSession.Error.concurrentRequests`** (the new 27 type); the first request completes |
| Text streaming | Cumulative snapshots; 12 over 2.0 s; first at ~350 ms | Cumulative snapshots; **65** over 2.1 s (much finer-grained); first at ~1.1 s |
| `@Generable` output | Pass: nested struct, enum, `.range` and `.count` guides all held | Pass, same |
| `@Generable` streaming | Properties fill in order; the array grows one element at a time: `[0,1,2,3]` | Same; 27 snapshots vs. 6 |
| Runtime schema, unanchored pattern | Pass, exactly `2026-09-22T09:00` | Pass |

Consequences for the design:
- **The runtime must serialize requests per session.** Both OS versions reject a second concurrent request, with different error types.
- **Conversation persistence (M2-04) can store the framework's own `Codable` transcript** instead of inventing a format.
- **Streaming UI must treat each snapshot as the full text so far, not a delta.** The snapshot rate varies about 5× between hosts.
- **Budgets should use `tokenCount` at run time.** Per-component counts differ between OS versions even where totals agree (§10).

### 9a. Abandoning a stream, then reusing the session, crashed on macOS 26 but not on iOS 27 🔴

This is the most consequential P0-02 result, because it constrains how the runtime implements cancellation (NFR "support cancellation", `AgentTool.isCancellable`).

**Behavior on both hosts:**
- **Cancellation doesn't throw.** `Task.cancel()` ends the stream's `for try await` loop **normally**: no `CancellationError` (macOS 3/3, iOS 1/1). Code that detects cancellation by catching the error will never see it.
- **The transcript is rolled back asynchronously.** Right after abandonment the transcript still holds `[prompt,response]`; **by t=25 ms it is back to `[]`**. `isResponding` already reads `false` at t=0. That's 6/6 on macOS and 2/2 on iOS, so `isResponding` going false does not mean the session has settled.

**macOS 26.6.2 only: reuse crashes the process.** Abandoning a stream (by `Task.cancel()` or `break`) and then sending the next request on the *same* session immediately killed the process 3/3: SIGTRAP or SIGSEGV, `EXC_BREAKPOINT` in a FoundationModels frame, nothing on stderr. A fresh session passed 3/3, and the same session after a 100–1000 ms wait passed 6/6 (timing luck, not a guarantee). A copy of the transcript taken during the rollback window carried the abandoned prompt, and a session rebuilt from it answered the *abandoned* prompt instead of the new one in 2 of 3 runs.

**iOS 27.0 on the iPhone: no crash.** The same immediate reuse passed **8/8**, abandoning at 1, ~27, and 55–73 snapshots. Each time the session answered the new prompt and ended with only the new exchange (2 entries). `LanguageModelSession.Error.transcriptMutationWhileResponding`, new in 27, was never thrown.

**Can't yet say whether macOS or OS 26 is at fault.** No iOS 26 device and no macOS 27 host were available; a macOS 27 host would settle it.

**The safe pattern, verified on both hosts:** snapshot `session.transcript` **before** starting a stream; after abandoning it, **discard the session and rebuild from the snapshot**. This doesn't depend on timing, and it's correct on both OS versions.

**For Milestone 1 (not yet acted on):**
- `AgentRuntime` should own its transcript and treat a `LanguageModelSession` as disposable after any abandoned request.
- It should track cancellation itself rather than infer it from errors, and never use `isResponding` as the signal that a session is ready.
- As long as macOS 26 is inside the deployment range (PLANNING §6 question 9), this is required for correctness, not an optimization.

### 9b. Anchored regex guides are rejected on both OS versions: untyped on 26, typed on 27

A `GenerationGuide.pattern` written with `^…$` was refused every time on both hosts, whether the field was optional or required:
- **macOS 26.6.2 (4/4):** an untyped `NSError` (domain `LanguageModelSession.GenerationError`, code −1) wrapping `GenerativeError` 1020000, with no message. It doesn't match any typed `GenerationError` case.
- **iOS 27.0 (4/4):** a typed **`LanguageModelError.unsupportedGenerationGuide`**. 27 fixed the error reporting, not the restriction.

The same pattern without anchors works on both, and the output still matches the whole value. With no pattern at all, the Mac wrote `2026-09-22T09:00:00` (extra seconds, 2/2), while the iPhone wrote the exact format (2/2). Guides are what make the format reliable across OS versions.

Consequences, already applied: `EvalSuites/phase0/tools.json` had three anchored patterns that would have failed every datetime goal at run time. They're now unanchored, the file states the rule, and the validator rejects anchors. For FR-025: the `AgentError` mapping must handle untyped framework `NSError`s on OS 26, not only the typed enums.

### 9c. OS 27 replaces the error types that P0-13 relied on

Building the spike for iOS 27 failed on a deprecation: **`LanguageModelSession.GenerationError` is deprecated in iOS/macOS 27.** It's split into:

- `LanguageModelError` (model outcomes): `contextSizeExceeded`, `rateLimited`, `guardrailViolation`, `refusal`, `unsupportedCapability`, `unsupportedTranscriptContent`, `unsupportedGenerationGuide`, `unsupportedLanguageOrLocale`, `timeout`
- `LanguageModelSession.Error` (session misuse): `concurrentRequests`, `transcriptMutationWhileResponding`

**P0-13's conclusion still holds on 27, structurally:** `guardrailViolation` and `refusal` remain distinct typed cases. But the *type* a provider must catch differs by OS version. On the iPhone, the new types were confirmed at runtime for `concurrentRequests` (`LanguageModelSession.Error`) and `unsupportedGenerationGuide` (`LanguageModelError`); a guardrail or refusal on 27 hasn't been triggered yet. `FoundationModelProvider` (M1-PR-03, `.refused`) must map both generations of error types, which is one more input to the deployment-floor decision in PLANNING §6 question 9.

### Unrelated system noise, recorded so nobody chases it

`intelligencetasksd` was crash-looping on this Mac, with launchd backoff doubling from 10 s, **starting at 19:23, 14 minutes before the first spike run**. Model calls were unaffected throughout. It's not caused by the spike.

## 10. Context budget under realistic load (P0-08): tool definitions take a quarter of the context

**2026-09-19.** From the P0-08 fixture ([`EvalSuites/phase0/context-load.json`](../EvalSuites/phase0/context-load.json)), measured with the real `SystemLanguageModel.tokenCount` on **macOS 26.6.2** and on the physical **iPhone 15 Pro, iOS 27.0**. The fixture is a work-assistant session: 12 conversation exchanges including tool calls and outputs, 16 retrieved document chunks, and a 5-step plan. Each profile was assembled into a real transcript by the spike's `context-size` check.

| Component | macOS 26.6.2 | iOS 27.0 | Share of 4,096 |
|---|---|---|---|
| **8 tool definitions** (the catalog) | **1,063** | **1,045** | **~26%**, on every request |
| Instructions | 129 | 161 | 3–4% |
| 12 exchanges of history, with tool traffic | 1,476 | 1,487 | 36% |
| …the same history, prompts and responses only | 809 | 826 | 20% |
| 16 retrieved chunks (~55–70 words each) | 1,379 | 1,342 | 33% |
| Plan state (5 steps) | 124 | 112 | 3% |

| Profile | Content | macOS total | iOS total | Of context | Left for the answer |
|---|---|---|---|---|---|
| light | 3 exchanges, 3 chunks | 1,779 | 1,756 | 43% | ~2,330 |
| typical | 8 exchanges, 6 chunks, plan | 2,723 | 2,694 | 66% | ~1,390 |
| heavy | 12 exchanges, 10 chunks, plan | 3,694 | 3,664 | **89–90%** | **~400–430** |
| stress | 12 exchanges, 16 chunks, plan | 4,189 | 4,148 | **101–102%** | **none: over the limit before the model writes anything** |

What this shows, before P0-12 has measured any failures:

- **Tools are the biggest fixed cost.** Registering the 8 built-in tools on every request spends about a quarter of the context, on both OS versions. Each tool costs about as much as one conversation exchange. For `ContextBudgeter` (M1-RT-04), "system + tools" is the dominant fixed share, so **per-request tool selection** (registering only the tools relevant to the current step) is likely worth more than aggressive history trimming. That's a design input, not yet a decision.
- **Tool traffic nearly doubles history.** The tool calls and outputs inside the conversation account for ~45% of its tokens (1,476 vs. 809). Compacting old tool outputs is a second cheap lever.
- **The limit is reached by ordinary content.** A long but normal session with generous retrieval (heavy) leaves ~400 tokens for the reply; 6 more chunks (stress) exceed the window before generation starts. R2 is a real constraint at realistic sizes, not only under abuse.
- **"Headroom" is the answer budget.** The context holds the input *and* the output, so a request at 90% can still fail if the reply runs past ~400 tokens. P0-12 should record whether failures come at request time or mid-generation.
- **For identical content the two OS versions agree within ~2% in total.** Individual components differ, instructions most (161 vs. 129). The profiles therefore need no per-OS resizing, but budgets should still be computed with `tokenCount` at run time rather than from constants.

### 10a. iOS 27 rejects a transcript whose tool outputs don't answer a tool call

The first iPhone run failed to count any history. `tokenCount(for:)` threw an untyped `NSError` (domain `LanguageModelError`, code −1) wrapping `ModelManagerServices.ModelManagerError 1001`, with no further explanation. It happened for every profile, twice. The cause was the fixture's assembly: each `Transcript.ToolOutput` had a fresh id instead of the id of the `Transcript.ToolCall` it answers. With outputs linked to their calls, every count succeeds. **macOS 26.6.2 accepted the unlinked transcript and returned counts; iOS 27 rejects it.**

This matters beyond the spike. Anything that **builds or restores a transcript** rather than letting the session write it (conversation persistence M2-04, context trimming and summarization in `ContextBudgeter`, the eval runner) must keep every tool output's id equal to its call's id. The error that signals a violation doesn't say so.

The fixture's probes plant facts at known positions (oldest exchange, a mid-session user statement, the newest exchange, an early and a late chunk, the plan). P0-12 can then separate the two failure modes: an explicit context-size error, and silent loss where the request succeeds but a fact in context is missed, or a fact trimmed out of context is hallucinated.

## 11. Structured tool-call validity (P0-09): 51% on macOS 26, 63% on iOS 27, far below the 95% bar

**2026-09-19.** The P0-05 single-tool suite (20 goals, all 8 catalog tools registered) run **5 times per goal, 100 runs per host**, each in a fresh session, through the spike's `p0-09` check. The instructions were minimal and recorded verbatim: *"You are the assistant in a work app. Now is Monday 2026-09-21 10:00 (UTC). Use the available tools to act on the user's request."* The first tool call of each run is scored, and schema validity is checked independently against the catalog rather than trusted from the framework. Raw per-run logs and the scorer are in [`phase-0-results/`](phase-0-results/).

| | macOS 26.6.2 | iPhone 15 Pro, iOS 27.0 |
|---|---|---|
| A tool was called | 95% | 71% |
| Schema-valid call | 95% | 71% |
| Right tool | 85% | 63% |
| Right tool and right arguments | 51% | 63% |
| **First call fully correct** | **51%** | **63%** |
| Runs with follow-up calls | 27% | 45% |

| Why runs failed | macOS 26.6.2 | iOS 27.0 |
|---|---|---|
| Right tool, **wrong arguments** | **34**: optional `due` left out 11, wrong date/time 9, calculator syntax 7, missing search term or enum 7 | **0** |
| **Tool call was unparseable JSON** | 0 | **25** |
| Wrong tool | 10 | 8 |
| Other error, no call | 5 (untyped `GenerationError` −1 wrapping `tokengeneration` code 10) | 1 (the model ran past the 4,096 context on a single request) |
| Answered in text, no call | 0 | 3 |

**Neither host is anywhere near the M5 target of >95% tool-execution success.** That's the R1 question, and this is the first real evidence on it. P0-15 formally needs P0-10's multi-step completion rate too, but with single calls correct only half to two-thirds of the time, a model-driven planner chaining 3–5 of them would need a large improvement from somewhere. Recorded as evidence for P0-15, not a decision.

### 11a. The framework does not guarantee schema-valid tool calls on iOS 27

The EvalSuites README predicted that guided generation would make the literal P0-09 metric near 100% "by construction". **That's true on macOS 26 (every call that reached us was valid) and false on iOS 27.**

On the iPhone, **every run of every goal whose tool takes a date-time argument, 25 of 25**, produced malformed JSON the framework itself couldn't parse (`GeneratedContent.ParsingError`), with an identical shape each time:

```
{"end":\"2026-09-22T00:00\",start:\"2026-09-21T00:00\"}<ctrl43>
```

The quotes around each value are escaped, the second key is unquoted, and a stray control token follows. The values inside were often right: st-05's `2026-10-02T00:00`–`23:59` was correct in all 5 broken calls. The corruption is therefore in how the output is constrained, not in what the model meant.

A diagnostic matrix on the `create_reminder` goals (3 goals × 3 runs per cell) narrowed it down:

| `due` declared as | macOS 26.6.2 | iOS 27.0 |
|---|---|---|
| optional + pattern (the catalog as shipped) | valid JSON, but `due` never filled | broken JSON |
| optional, no pattern | valid JSON, but `due` never filled | **valid, and `due` correct 5/5** |
| required + pattern | **valid, and `due` correct 8/8** | broken JSON |
| required, no pattern | not tested | broken JSON |

**No single declaration of a date field worked on both OS versions.** The one working iOS form (optional, no pattern) is a form macOS 26 never fills. Whether dropping the pattern also fixes the calendar's *required* `start`/`end` on iOS is untested: the phone disconnected before that run.

### 11b. Optional tool arguments are never filled on macOS 26

Across the suite and the diagnostics, macOS 26 filled the optional `due` argument **0 times in 20+ `create_reminder` calls**, including "tomorrow at 9am" and "the 30th at 5pm". The titles often ended in a stray comma (`"Submit Quarterly Report,"`), as if the model had started a next field that the decoder cut off. Declaring the same field **required** produced correct dates **8/8**. So the model can do it; the optional form suppresses it. A side effect: st-08 ("no date given, so `due` must be absent") passes trivially on macOS 26 for the wrong reason.

### 11c. What the model gets wrong when the plumbing works

- **Relative dates.** "Tomorrow" was read as today in 5/5 runs on macOS, and the broken iOS calls show the same values. "Friday afternoon" was placed on Thursday or even Tuesday. This held even with the date and weekday stated in the instructions.
- **"Call X" reads as "look up X".** "Remind me to call the plumber" went to `search_contacts` in 5/5 iOS runs and some Mac runs; "Add a reminder to renew my passport" went to `search_contacts` 5/5 on macOS and 3/5 on iOS. For an agent that can chain calls, a contact lookup first is defensible, but it isn't what a single-step caller wants.
- **Loose argument formats (macOS).** The calculator got `17.5% of 2,480` and `$186.40 / 4` despite its description asking for numbers and `+ - * /`. iOS 27 never did this.
- **Confusable tools mostly separated.** On iOS, `search_files`, `search_documents` and `search_notes` were chosen correctly in every parsed call; on macOS a few lease/screenshot queries went to the wrong one.

### Design inputs for Milestone 1 (none acted on)

- **Argument validation in `ToolExecutor` is load-bearing, not a formality.** Framework-guided output can be unparseable (iOS 27) or silently incomplete (macOS 26). The runtime must parse and validate arguments itself and treat a `ParsingError` as a recoverable, retryable outcome, not a crash or a refusal.
- **Tool schemas need per-OS testing, and date/time arguments need a different encoding.** Candidates to measure: separate date and time fields, a natural-language date the tool resolves itself, or supplying resolved dates ("tomorrow = 2026-09-22") in context. `AgentTool` design (M1-CO-03) should treat schema shape as something the eval harness verifies.
- **Tools should accept loose input** (`17.5% of 2,480`) rather than fail on it; cheap to do, and it removes a whole failure class.
- **Date resolution probably shouldn't be left to the model** at this size.

**Caveats.** 20 goals × 5 runs per host; one instruction style; inert tools that always answer "No results found."; one OS build each. The two hosts differ in both OS version and platform, so a column difference can't be pinned on either alone. These are rates for *this* suite, not general capability claims.

## 12. Multi-step completion (P0-10): 14% as shipped, 28% with the framework bug removed (macOS 26; iPhone pending)

**2026-09-19.** The P0-06 multi-step suite (10 goals of 3–5 steps, all 8 tools registered, each goal's fixtures behind the tools, `calculate` evaluated for real) run **5 times per goal** through the spike's `p0-10` check, with the same instructions as P0-09. The framework runs the whole tool loop inside one `respond()`, so `maxIterations` is enforced from inside the tools. Steps are matched in dependency order, per the suite's scoring. **macOS 26.6.2 only so far**; the iPhone was unreachable. Logs and scorer are in [`phase-0-results/`](phase-0-results/).

Two configurations, because §11b showed macOS 26 never fills optional arguments, which would otherwise break every reminder step and turn this into a re-measurement of that bug:
- **As shipped:** the catalog unchanged. This is the headline number.
- **Workaround:** `--all-required`, the only difference being that optional arguments become required. That's safe for this suite, since every reminder in it names a time. The gap between the two runs is the framework's share; what remains is the model's.

| macOS 26.6.2, 50 runs each | As shipped | Workaround |
|---|---|---|
| **Goals completed end to end** | **14%** (7/50) | **28%** (14/50) |
| Required steps matched | 52% (81/155) | 59% (92/155) |
| Runs ended by a framework error | 1 | 4 |
| Runs that hit `maxIterations` | 0 | 0 |

**First reason each failed run failed:**

| | As shipped (43 failures) | Workaround (36 failures) |
|---|---|---|
| Called the step, but a value that had to come from earlier tool output was wrong (**grounding**) | 12 | **14** |
| Called the step with wrong arguments (dates, search terms, or the missing optional `due`) | **18** | 8 |
| Skipped a required step | 7 | 6 |
| Conditional goal: did the forbidden action (ms-10, $7 saving vs. a $10 threshold) | 5 | 4 |
| Framework error ended the run (untyped `GenerationError` −1 / `tokengeneration` 10) | 1 | 4 |

Per goal (workaround): ms-09 (conditional, branch taken) 5/5; ms-08 (recover from an empty search) 3/5; ms-04 2/5; ms-02, ms-03, ms-05 and ms-10 1/5; **ms-01, ms-06 and ms-07 0/5**. The three zeros are the grounded dentist phone number, the contract-notice date arithmetic, and the 5-step dinner plan.

**What this says about R1 (evidence for P0-15; the decision is P0-15's):**
- **End-to-end completion is far below the M5 bar.** At 28% even with the framework bug removed, a `ModelDrivenPlanner` that lets the model drive the loop would complete roughly one multi-step task in four on this host. PRD R1 and PLANNING §2.4 say that below the bar the default is `StateMachinePlanner`, a successful, shippable outcome.
- **The model mostly picks the right tools; it loses the thread between them.** Grounding is the largest failure class once the plumbing is fixed: the right tool is called, but the phone number, tip, email address, or deadline from the previous result doesn't make it into the next call. A state-machine planner that carries values between steps in code, and asks the model one narrow question per step, targets exactly this.
- **Simple structures work.** The conditional that should fire (ms-09) completed 5/5, and recovering from an empty search (ms-08) 3/5. The failures concentrate in carrying specific values and in date arithmetic.

**Caveats.** 10 goals × 5 runs on one host, one instruction style, fixture worlds, auto-approved confirmations. The iPhone numbers may differ materially: in P0-09, iOS 27 made *no* argument-value errors but broke date-time JSON (§11a), which would hit ms-01, 03, 05, 06, 07 and 09.

## Not yet done

Findings 1–2 are now resolved against the beta SDK; **the measurement half of Phase 0 has still not started.** Everything above is static SDK inspection plus small compile/run spikes (in scratch packages, not committed) — it is **not** a substitute for P0-01 through P0-14 as scoped:

- **P0-01 is committed** as [`Spike/`](../Spike/) (2026-09-18): an Xcode app for iOS 27 and macOS 26.4+ that compiles warning-free for both and runs on this Mac. The finding-2 BYO-LLM spike is still uncommitted scratch code.
- **P0-02 is done on both hosts** (§9). Still open from it: whether the §9a crash belongs to macOS or to OS 26 (needs a macOS 27 host), and triggering a guardrail or refusal on OS 27 to confirm the P0-13 cases under the new `LanguageModelError` type.
- **P0-10 is measured on macOS 26 only** (§12): 14% as shipped, 28% with the optional-argument workaround. The iPhone run (as shipped, plus a `--no-patterns` workaround run) is pending device availability.
- **P0-09 is measured** (§11): 51% / 63% first-call fully correct on macOS 26 / iOS 27. Follow-up: whether dropping the pattern also fixes required date fields on iOS 27 (phone disconnected before that run).
- P0-05, P0-06 and P0-07 are written (`EvalSuites/phase0/single-tool.json`, 20 goals; `multi-step.json`, 10 goals; `refusal.json`, 20 goals + 6 controls; all 2026-09-18) but **not yet run**. P0-08 (the context-load fixture) is written and sized on both hosts (§10). The M9 refusal threshold P0-11 needs has not been agreed.
- P0-09–P0-12 (the measured rates: tool-call validity, multi-step completion, refusal rate, context exhaustion) have not been produced — finding 6 is one trial, not a rate.
- **P0-15 (the planner GO/NO-GO) therefore cannot be called**, since it depends on P0-09/P0-10. Milestone 1 remains gated. 🔒
- P0-14 (latency/thermal/battery) has not been attempted — and still needs a *physical* Apple Intelligence device; neither this Mac nor a simulator can measure iPhone thermals.
- The `GenerationError.refusal` case (model-generated refusal, as distinct from `guardrailViolation`) has not been triggered or inspected at runtime.
- **New, from finding 2:** the `LocalModelProvider` / `LanguageModel` overlap and the resulting **macOS/iOS 27 deployment-floor decision** are open and block finalizing FR-003/FR-004 and `Package.swift`. This is a design call for the user.
- **New, from finding 1:** FR-004's `CoreAIModelProvider` should be re-specified or dropped — `CoreAIRuntime` is a tensor API, not a text-generation one.
- Runtime verification on **macOS** 27 awaits the beta OS; the beta *SDK* is installed, the beta *OS* is not.
