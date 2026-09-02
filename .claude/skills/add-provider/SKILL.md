---
name: add-provider
description: Add or modify a LocalAgentKit provider — a model, memory, embedding, vector store, vision, or speech implementation — without breaking the layering rule that keeps Core and Runtime free of Apple-framework imports. Use for any M1-PR / M2 / M3 / M4 provider task, or when asked to "wrap <framework>", "add support for <model runtime>", or "swap the <embedding|memory|vector> backend".
---

# Adding a provider

Providers are the **only** place concrete frameworks enter the SDK. Everything above them talks to protocols. Getting this wrong is what makes metric M3 ("replace the model provider without modifying AgentCore") quietly stop being true.

## 1. Verify the real API before writing a line 🔒

`PLANNING.md` §6 open question 1 is still open: this project's design was written from the PRD's account of WWDC 2026 announcements, not from the shipping SDK.

**Do not write Swift against Foundation Models, Core AI, or any Apple framework from memory.** Model knowledge of these APIs is unreliable and the failure mode — plausible-looking code that does not compile, or worse, compiles against a hallucinated overload — costs more than checking.

Before implementing, confirm from the installed SDK or official documentation:

- exact module name and `import`
- availability annotations (`@available`) for the deployment target
- the real initializer / session / lifecycle API
- for model providers: the structured-output API and how a policy refusal surfaces (open question 3)

Read the headers directly when in doubt — the SDK on disk is the source of truth, not recollection. If the API cannot be verified, say so and stop rather than guessing.

## 2. Pick the protocol and the target

| Providing | Protocol | Lives in |
|---|---|---|
| Inference | `LocalModelProvider` | `Sources/LocalAgentKitProviders/<Name>ModelProvider/` |
| Memory persistence | `MemoryStore` | `Sources/LocalAgentKitProviders/<Name>MemoryStore/` |
| Embeddings | `EmbeddingProvider` | `Sources/LocalAgentKitProviders/<Name>EmbeddingProvider/` |
| Vector search | `VectorStore` | `Sources/LocalAgentKitProviders/<Name>VectorStore/` |
| Vision | `VisionProvider` | `Sources/LocalAgentKitProviders/<Name>VisionProvider/` |
| Speech | `SpeechRecognizer` / `SpeechSynthesizer` | `Sources/LocalAgentKitProviders/<Name>SpeechProvider/` |

**Never** in `LocalAgentKitCore` or `LocalAgentKitRuntime`. If implementing the provider seems to require changing Core, the protocol is wrong — fix the protocol, don't leak the framework.

## 3. The layering rule

`Core` and `Runtime` must not import `FoundationModels`, `CoreAI`, `SwiftData`, `Vision`, `Speech`, `EventKit`, `Contacts`, or `SwiftUI`. CI enforces this (task M0-13).

If the protocol can't express what your provider needs, the fix is a **framework-agnostic** addition to the protocol — expressed in Core's own value types, never in the framework's. A protocol requirement that takes or returns an Apple framework type has leaked the abstraction just as surely as an import would.

## 4. Implement

- `Sendable`, `async throws` — Swift 6 strict concurrency, complete checking, no `@unchecked Sendable` escape hatches
- Translate every framework error into a typed `AgentError`. A raw `NSError` reaching the runtime is a bug
- Honor `Task` cancellation at every `await` (FR-024)
- No `fatalError` in library code — an unavailable model is `.modelUnavailable`, not a crash

### Model providers specifically

- Map the framework's output onto `ModelResponse` — including `.refused(GuardrailRefusal)`. **A refusal is never `.text` and never an error to retry** (R3). Retrying burns battery and context to fail identically
- Support streaming → `.responseToken` events where the framework allows it
- **Model lifecycle is shared, not per-agent.** Two `LocalAgent` instances in one app must not each hold a model in memory: lazy load, reference-count, unload (task M1-PR-04, open question 6)
- Sit *on top of* Apple's bring-your-own-model support — do not re-implement it (PRD §6 non-goals)

### Network-touching providers

If a provider can reach the network under any configuration, it must declare that so `NetworkPolicyGuard` can reject it at construction under `networkPolicy: .never`. Offline mode is a guarantee validated at startup, not a runtime surprise (FR-023). A provider that silently changes an app's network profile is the single worst bug this SDK could ship.

## 5. Ship a mock with it

Every provider protocol gets a counterpart in `Sources/LocalAgentKitTesting/` (standing task C-06). The unit suite must run with **no device and no network** (M1-TS-05) — if a new protocol has no mock, the suite starts requiring hardware and the coverage gate becomes untestable in CI.

For model providers, prefer a `ScriptedModelProvider` that replays a fixed response sequence, so loop, planner, and permission tests stay deterministic.

## 6. Tests

- [ ] Conformance tests against the protocol's contract, run through the mock
- [ ] Typed-error mapping: framework failure → the right `AgentError`
- [ ] Cancellation propagates
- [ ] For model providers: a guardrail refusal produces `.refused`, and the runtime does **not** retry it
- [ ] For network-capable providers: construction under `.never` throws
- [ ] Integration test on device/simulator, kept separate from the unit suite

## 7. Close the loop

- Add the provider to the framework table in `PLANNING.md` §3.2, naming the target that isolates it
- Tick the matching task in `TASKS.md`
- If this resolved a `PLANNING.md` §6 open question, move it to a decision record — an answered question doesn't just vanish (standing task C-07)
- Confirm the layering check still passes before opening the PR
