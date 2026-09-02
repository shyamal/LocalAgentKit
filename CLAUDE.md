# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state: pre-code

**There is no source code yet.** This repo contains three planning documents and a set of project skills. Not a git repo either — `git init` is task M0-01.

| File | Role |
|---|---|
| `LocalAgentKit-PRD-v0.2.md` | Source of truth for *what* and *why*. Requirements are cited as FR-0xx / NFR / R1–R5 / M1–M14 |
| `PLANNING.md` | Source of truth for *how* — architecture, stack, package layout, open questions |
| `TASKS.md` | ~180 tasks in 8 milestones with stable IDs (`M1-RT-07`) |
| `.claude/skills/` | Repeatable workflows — see below |

When the PRD and any other document disagree, the PRD wins and the other document needs fixing.

## Commands

**None of these run yet** — there is no `Package.swift`. They are the intended workflow once M0-03 lands, and are what CI will enforce.

```bash
swift build                                    # must be warning-free under Swift 6 strict concurrency
swift test                                     # full unit suite — must pass with no device and no network
swift test --filter <TestName>                 # single test or suite
swift test --enable-code-coverage              # 80% gate applies to Core + Runtime only (metric M4)
swift-format lint --recursive Sources Tests    # CI-enforced

# The layering check — any output is a build failure (task M0-13)
grep -rnE '^import (FoundationModels|CoreAI|SwiftData|Vision|Speech|EventKit|Contacts|SwiftUI)' \
  Sources/LocalAgentKitCore Sources/LocalAgentKitRuntime
```

Device work needs an Apple silicon Mac plus a physical Apple Intelligence-capable device — the on-device model's behavior, thermals, and battery cost cannot be measured in the simulator. Keep the latest Xcode beta installed side by side; the FR-029 harness runs against OS betas to catch model drift (R4).

## Architecture: the parts that span files

Read `PLANNING.md` §2 for the full picture. The load-bearing decisions:

**The layering rule.** `LocalAgentKitCore` (protocols + value types) and `LocalAgentKitRuntime` (the agent loop) must not import any Apple framework. Concrete frameworks live only in `LocalAgentKitProviders` and `LocalAgentKitTools`. Dependency direction is strictly one-way: Tools/Providers/SwiftUI → Runtime → Core. This is what makes metric M3 ("swap the model provider without touching AgentCore") true, and it's enforced by grep in CI rather than by convention. If a provider seems to require changing Core, the protocol is wrong — extend the protocol in Core's own value types, never with a framework type.

**Ordering inside the agent loop is the security model.** `ToolExecutor` runs validate arguments → permission gate → execute → observe. A schema-valid tool call produced by text injected into an ingested document is stopped at the gate and nowhere else. Structured tool calls are *not* the injection defense; the permission tiers are (PRD §19). Nothing above `.readOnly` executes without explicit human confirmation, and no runtime flag may downgrade a tier.

**Three runtime behaviors are counterintuitive and deliberate:**
- *Guardrail refusals are terminal, never retried.* The on-device model refuses ordinary business tasks touching health/finance/legal phrasing (R3). A retry burns battery and context to fail identically. Refusals surface as a typed `.refused(GuardrailRefusal)`, distinct from errors, so apps can fall back to a non-agentic path.
- *Context budgeting runs before every model call, not on failure.* `ContextBudgeter` allocates configurable shares to system+tools / conversation / RAG / plan state, then trims and summarizes. `contextLimitExceeded` is what's left after both fail — not the first line of defense (R2).
- *Permission prompts suspend via continuation.* No thread and no lock is held while waiting on a human.

**Two planners, one protocol.** `StateMachinePlanner` (deterministic, model consulted per-decision) and `ModelDrivenPlanner` (model emits and revises whole plans) both ship. Phase 0 measurement decides which is `.default` — a one-line config change instead of an architecture rewrite, because R1 (can a compact on-device model drive multi-step planning?) is genuinely unresolved.

**`AgentTool` carries two requirements beyond the PRD's protocol:** `isParallelSafe` and `isCancellable`. The runtime cannot schedule parallel execution or propagate cancellation correctly without tools declaring both honestly.

## Gates — do not jump these 🔒

The PRD added "validated, not assumed" (§23.13) because v0.1 shipped assumptions v0.2 had to walk back. `TASKS.md` marks gates with 🔒:

- **Phase 0 gates all of Milestone 1.** No SDK code before the feasibility spike reports. "The spike hasn't run yet" is the correct answer to "start building the runtime."
- **P0-03** (verify the real Foundation Models / Core AI API against the shipping SDK) blocks finalizing `Package.swift`
- **P0-04** (is a tokenizer exposed?) blocks `ContextBudgeter` design
- **P0-13** (is a policy refusal programmatically detectable?) blocks the FR-005 `.refused` design
- **P0-15** is the planner GO/NO-GO
- **M3-04** (embedding quality benchmark) gates the rest of RAG

If asked to do work that jumps a gate, say so rather than quietly proceeding.

## Never write Apple framework code from memory

This project's design was written from the PRD's account of WWDC 2026 announcements — Foundation Models accepting third-party/MLX providers, Core AI replacing Core ML. `PLANNING.md` §6 question 1 is still open. Confirm module names, availability annotations, and the real initializer/session APIs against the installed SDK headers or official docs before writing Swift against them. If the API can't be verified, say so and stop; plausible-looking code that compiles against a hallucinated overload costs more than checking.

## Conventions

- Swift 6, strict concurrency, complete checking. No `@unchecked Sendable`, no silenced warnings.
- Target **zero runtime dependencies**. Dev/test-only deps (`swift-testing`, `swift-docc-plugin`, `swift-format`, `swift-argument-parser` for the eval CLI) are the permitted exceptions; anything new needs written justification in the PR.
- Typed `AgentError` throughout; no `fatalError` in library code.
- Every new protocol ships with a mock in `LocalAgentKitTesting` — the unit suite must never start requiring hardware.
- Every new observable runtime state emits an `AgentEvent`.
- Commit messages reference the task ID: `M1-RT-07: order permission gate after arg validation`. Task IDs are stable — append, never renumber.
- Answered `PLANNING.md` §6 open questions move to a decision record with their evidence; they don't silently vanish.

## Skills

`.claude/skills/` holds four project workflows, auto-loaded when a task matches or invokable as `/<name>`:

- **add-agent-tool** — permission tier selection, schema design, the four required tests
- **add-provider** — protocol/target choice, layering rule, model lifecycle, network-policy declaration
- **pr-check** — the definition-of-done gate; run before any commit or PR
- **update-tasks** — task hygiene, gate state, resolved open questions

Answer "where are we?" with gate state, not checkbox percentages — 60% of Milestone 1 means nothing if Phase 0 hasn't reported.
