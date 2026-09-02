# Phase 0 Findings

**Status:** In progress. This document accumulates verified findings as Phase 0 runs, per task P0-16 — it is not written only at the end. Everything below is either a direct reading of the shipping SDK or the output of a real program run on this machine, not a claim from memory or documentation.

**Environment:** macOS 26 (SDK MacOSX26.5), **Xcode 26.6 release toolchain only — no beta Xcode installed on this machine at the time of this finding** (see task M0-16, still blocked for the same reason), Swift 6.3.3, Apple silicon Mac, Apple Intelligence **enabled**. `SystemLanguageModel.default.availability == .available` on this machine — see finding 5.

---

## 1. `CoreAI.framework` — not present in the release SDK; **status pending beta verification**

**Update 2026-09-02, same day as the original finding:** the user reports Core AI is a beta framework and will install the beta toolchain to check. The finding below is accurate for what was actually inspected — the release SDK — but is **not** a final verdict on whether Core AI exists at all. Do not treat "resolved" (as this was briefly marked in `PLANNING.md` §6 and `TASKS.md` P0-03) as settled until re-checked against the beta SDK. Reverted to in-progress pending that check.

**Resolves part of `PLANNING.md` §6 open question 1 — partially, pending the above.**

The PRD (§1 Executive Summary, R5) asserts "Core AI has replaced Core ML as the modern on-device ML runtime." Searched the **release** SDK (Xcode 26.6, MacOSX26.5.sdk — no beta installed at the time):

```
$ ls MacOSX26.5.sdk/System/Library/Frameworks/ | grep -i "coreml\|coreai"
CoreML.framework
```

- `CoreML.framework` still exists, unreplaced, in the release SDK.
- `CoreAI.framework` does not appear anywhere in the release SDK — zero matches for "CoreAI" across the entire SDK tree (frameworks, headers, module maps).

**Conclusion, correctly scoped: Core AI is absent from the current release SDK.** Whether it exists in a beta SDK — which would make the PRD's premise correct, just ahead of general release rather than false — is unverified and is the very next thing to check once the beta toolchain is installed. `FR-004`'s `CoreAIModelProvider` and other PRD/PLANNING references should not be treated as debunked on the strength of this finding alone.

## 2. Foundation Models — no third-party / BYO-LLM / MLX registration API found in the release interface; **also pending beta verification**

**Same caveat as finding 1:** this was checked against `FoundationModels`' release `.swiftinterface` only. `FoundationModels` itself is GA, not beta, but BYO-LLM/MLX registration could plausibly still be a beta-only *capability* added to an already-GA framework (e.g. via new API surfacing in a beta SDK's `.swiftinterface` for the same module) rather than requiring a wholly new framework. Not treating this as fully settled either, pending the same beta-toolchain check as finding 1.

**Resolves the other half of open question 1 — partially, pending the above.**

The PRD (§1, §4 G1, FR-004, R5) repeatedly asserts Foundation Models "now accepts third-party and custom LLM providers (including MLX models) directly." Read the actual public API surface directly from the framework's `.swiftinterface` (the real compiled interface, not documentation):

```
MacOSX26.5.sdk/.../FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface
```

Full public type list, and a grep for `mlx|third.?party|custom.?llm|bring.?your|external.?model` across the entire interface, returned **zero matches**. The only model-customization mechanism exposed is:

```swift
public struct Adapter {
    public var creatorDefinedMetadata: [String: Any] { get }
}
extension SystemLanguageModel.Adapter {
    public init(fileURL: URL) throws
    public init(name: String) throws
    public func compile() async throws
    public static func compatibleAdapterIdentifiers(name: String) -> [String]
}
```

This is Apple's own LoRA-style fine-tuning adapter mechanism for **specializing Apple's own on-device base model** — not a mechanism for registering an arbitrary third-party or MLX model as the backing LLM. There is no API that lets an app supply its own model weights/runtime and have `SystemLanguageModel` or `LanguageModelSession` use them instead of Apple's model.

**Conclusion, correctly scoped: no such mechanism was found in the release interface.** `SystemLanguageModel` gives you Apple's on-device model (optionally adapter-specialized) as far as the release `.swiftinterface` shows. Whether a beta SDK exposes more is the open question — not yet a settled "does not exist."

### Why this would matter if it holds up — not yet acted on

*(This subsection describes the implication **if** findings 1–2 hold after the beta check. It's kept here rather than deleted so the reasoning isn't lost, but nothing in `PLANNING.md` should be treated as finalized on this basis until that check happens.)*

The PRD's R5 ("Shrinking model-abstraction differentiation") argues LocalAgentKit's `LocalModelProvider` protocol is *less* valuable now because Apple provides model abstraction itself. If findings 1–2 hold after beta verification, that argument's premise would be false: Apple would not let you swap the underlying model at all through this API, which would make `LocalModelProvider` (as a protocol with sibling implementations — a `FoundationModelProvider` wrapping `SystemLanguageModel`, and, separately, a genuinely independent llama.cpp/MLX-direct provider implementing the *same protocol*) **more** valuable than the PRD assumed, not less. If the beta check instead confirms BYO-LLM/Core AI exist, this whole subsection is moot and the PRD's original R5 reasoning stands.

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

## Not yet done

Everything above came from static SDK inspection plus ad hoc single-run experiments (in a scratch SwiftPM package, not committed to this repository) — it is **not** a substitute for P0-01 through P0-14 as scoped:

- **Beta SDK check (highest priority next step) — user is installing a beta Xcode/OS toolchain to check whether Core AI and/or BYO-LLM/MLX registration exist there.** Findings 1 and 2 above are not final until this happens; treat them as "absent from release, unknown in beta," not "does not exist." This also unblocks task M0-16 (Xcode beta side-by-side), which was blocked for the identical reason (no beta installed).
- No formal, repeatable P0-01 spike artifact exists in-repo yet.
- P0-05/P0-06/P0-07 (the actual 20/10/20-goal evaluation suites) have not been written.
- P0-09–P0-12 (the actual measured rates) have not been produced — finding 6 is one trial, not a rate.
- P0-14 (latency/thermal/battery) has not been attempted — this machine can inform macOS latency but not iPhone thermal/battery behavior.
- The full `GenerationError.refusal` (model-generated refusal, as opposed to `guardrailViolation`) has not been triggered or inspected at runtime.

**Explicitly paused here at the user's direction (2026-09-02)** — not continuing to P0-05 onward, not formalizing the spike in-repo, until the beta check above happens.
