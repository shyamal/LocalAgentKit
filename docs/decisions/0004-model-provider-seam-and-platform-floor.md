# 0004: `LocalModelProvider` stays as the Core seam; floor is macOS/iOS 26.4

**Status:** Accepted, 2026-09-26 — resolves PLANNING §6 open question 9
**Relates to:** PRD FR-003, FR-004, FR-005, R5, metric M3; findings §1, §2, §9–§14; tasks M1-CO-01, M1-PR-01, M1-PR-03, M1-PR-06, M0-13

## Context

`PLANNING.md` specified `LocalModelProvider`, a LocalAgentKit protocol abstracting the model so an app could swap Foundation Models for llama.cpp or MLX (FR-003/FR-004). Phase 0 then found Apple ships that seam itself: the public `LanguageModel` + `LanguageModelExecutor` protocols, with `LanguageModelSession` generic over them, verified by compiling and running a non-Apple model through a stock session (findings §2). The PRD's R5 concern — that Apple now does model abstraction, shrinking our differentiation — is therefore correct.

That left three options: drop our protocol and use Apple's; keep ours with a thin adapter; or invert and ship `LanguageModelExecutor` conformances as the product. The catch is that **Apple's seam is OS 27 only**, while macOS 26 is where most of Phase 0's rough edges live.

## Decision

**1. `LocalModelProvider` stays in `LocalAgentKitCore` as the model seam.** `FoundationModelProvider` adapts it to `SystemLanguageModel` (M1-PR-01). On OS 27 a second adapter can wrap any `LanguageModel` conformance, so an app that brings its own model through Apple's protocol is supported without Core knowing about it (new task M1-PR-06).

**2. The deployment floor is macOS 26.4 / iOS 26.4**, not 27, and not 26.0. `SystemLanguageModel.tokenCount(for:)` is 26.4+, and `ContextBudgeter` (M1-RT-04) must budget against real token counts rather than estimates (findings §3). OS 27-only API — `LanguageModel`, `LanguageModelError`, `LanguageModelSession.Error`, `GenerationOptions.toolCallingMode` — goes behind `#available` checks.

**3. FR-004's `CoreAIModelProvider` is dropped, not deferred.** `CoreAIRuntime` is a tensor/NDArray inference API; text generation on it would mean hand-rolling tokenization, KV-cache and sampling (findings §1). `PLANNING.md` §2.2's package tree drops that directory.

## Why option 2, on the evidence

The deciding factor is not architectural taste. Phase 0 measured the two OS versions behaving like different models, and **every difference needs a workaround that has to live somewhere**:

| | macOS 26 | iOS 27 | § |
|---|---|---|---|
| Optional tool arguments | never filled | filled correctly | §11b |
| Date arguments with a pattern guide | work | **unparseable JSON** | §11a |
| Facts present in context that reach the answer | 55% | 100% | §14 |
| Refusals on benign tasks (M9) | **FAIL** | pass | §13 |
| Error types | `GenerationError` | `LanguageModelError` + `LanguageModelSession.Error`, plus untyped `NSError`s | §9c, §11b |
| Session reuse after an abandoned stream | **crashes** | safe | §9a |

These conflict: the date-field shape that works on one host fails on the other (§11a). A seam we own is where that is absorbed. If `Core` talked to `FoundationModels` directly, the quirks would leak into the runtime and into app code — and Core would have to import an Apple framework, breaking the layering rule and metric M3 that CI enforces (M0-13).

Two supporting reasons: mapping guardrail refusals to a typed `.refused` (FR-005, M1-PR-03) means handling two generations of error types plus untyped ones, which is provider work by definition; and the unit suite must never require hardware, which needs a protocol that can be mocked in `LocalAgentKitTesting`.

## Consequences

- **`Package.swift` platform floor is now final**: `.iOS("26.4")`, `.macOS("26.4")`.
- **We support an OS with known bad behaviour, deliberately.** macOS 26 fails M9 and reads ~55% of its context. That is precisely why R3's fallback UX is v0.1 scope (decision 0001) and why the runtime owns validation, retries and per-call deadlines rather than trusting the model.
- **Per-OS quirks belong in the provider, with the eval harness as the guard.** The workarounds Phase 0 identified — required rather than optional arguments, no anchored or date pattern guides, lenient ISO-8601 parsing in tools, rebuilding a session from a pre-stream transcript snapshot after cancellation — are `FoundationModelProvider` concerns, and FR-029 re-checks them per OS version (R4).
- **R5 is answered, not dismissed.** Apple's abstraction is real, so `LocalModelProvider` is no longer pitched as the differentiator; it is the compatibility and testability seam. The product value sits where the PRD v0.2 moved it: the agent loop, permissions, memory, RAG.
- **Reversible if the floor rises.** If the project later requires OS 27, the adapter collapses into a thin conformance and nothing above it changes.

## The trade, stated plainly

Requiring OS 27 would avoid the crash, the optional-argument bug, the untyped errors and the 55% recall, and would let the provider be a few lines over Apple's protocol. It would also exclude every macOS 26 and iOS 26 user, and would not avoid the iOS date-JSON bug. Supporting 26.4 keeps those users at the cost of carrying documented workarounds in one place.
