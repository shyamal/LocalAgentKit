# Contributing to LocalAgentKit

## Before you start

This project is pre-alpha — see [`README.md`](./README.md) for current status. Two things matter more here than in most repos:

1. **Check [`TASKS.md`](./TASKS.md) first.** Work is tracked as task IDs (`M1-RT-07`) grouped into milestones. If what you want to build already has an ID, use it. If it doesn't, add one in the right milestone before opening a PR — untracked work is invisible to the roadmap.
2. **Respect the 🔒 gates.** Milestone 1 (the actual SDK) is gated on the Phase 0 feasibility spike, which has not run yet. Don't build agent-loop or model-integration code ahead of it — see [`PLANNING.md`](./PLANNING.md) §5 for why, and [`CLAUDE.md`](./CLAUDE.md) for the current gate list. If you think a gate should be crossed, say so in an issue rather than doing it in a PR.

No license has been chosen yet (task M0-10) and there is no CI running (tasks M0-11–M0-16). Both are Milestone 0 work; contributions before they land are at your own risk.

## Prerequisites

- Apple silicon Mac, latest Xcode, Swift 6.x
- A physical Apple Intelligence-capable device for anything touching model inference, thermals, or battery — the simulator can't measure these

See `README.md` → Platform requirements.

## Adding a tool

A tool is the only way an agent affects the world, so the permission tier is the decision that matters most:

| Tier | Use when | Confirmation |
|---|---|---|
| `.none` | Pure computation, no I/O | No |
| `.readOnly` | Reads data the app already has access to | No |
| `.userConfirmation` | Creates or modifies user data, recoverable | **Yes** |
| `.sensitive` | Reading it is itself the risk (contacts, health, location) | **Yes** |
| `.destructive` | Irreversible — delete, send, spend | **Yes** |

Pick by asking "what happens if a manipulated model calls this with attacker-chosen arguments?" — not by how the tool is normally used. When torn between two tiers, take the higher one.

Target: a complete tool in under 100 lines of application code (metric M2). If Claude Code is available, `/add-agent-tool` walks the full process — schema design, the `isParallelSafe`/`isCancellable` declarations, and the four required tests (happy path, invalid arguments, permission gate, cancellation).

## Adding a provider

Providers (model, memory, embedding, vector store, vision, speech) are the only place concrete Apple frameworks may be imported. `LocalAgentKitCore` and `LocalAgentKitRuntime` must stay framework-free — this is enforced by CI, not convention (task M0-13):

```bash
grep -rnE '^import (FoundationModels|CoreAI|SwiftData|Vision|Speech|EventKit|Contacts|SwiftUI)' \
  Sources/LocalAgentKitCore Sources/LocalAgentKitRuntime
```

Any output is a failure. If a provider seems to need a change to Core, the protocol is wrong — extend it with Core's own value types, never with a framework type.

**Do not write Apple framework code (Foundation Models, Core AI, etc.) from memory.** This project's design was written from the PRD's account of WWDC 2026 announcements, not a verified shipping SDK — see `PLANNING.md` §6, open question 1. Confirm module names, availability annotations, and real APIs against the installed SDK before writing against them.

If Claude Code is available, `/add-provider` covers the full process, including the model-lifecycle and network-policy requirements providers must satisfy.

## Development workflow

```bash
swift build                                    # must be warning-free under strict concurrency
swift test                                     # full suite — must pass with no device and no network
swift test --filter <TestName>                 # single test or suite
swift test --enable-code-coverage              # 80% gate on Core + Runtime (metric M4)
swift-format lint --recursive Sources Tests    # CI-enforced
```

Swift 6, strict concurrency, complete checking. No `@unchecked Sendable`, no silenced warnings, no `fatalError` in library code, no new runtime dependency without written justification (this SDK targets zero).

## Commits and PRs

- Reference the task ID: `M1-RT-07: order permission gate after arg validation`. Task IDs are stable — append new ones, never renumber existing ones.
- Every new protocol needs a mock in `LocalAgentKitTesting`. Every new observable runtime state needs an `AgentEvent`.
- Before opening a PR, run the checks above plus the layering grep. If Claude Code is available, `/pr-check` runs the full definition-of-done gate.
- Tick the task's checkbox in `TASKS.md` in the same PR that completes it.

## Security

No disclosure process exists yet (task M0-09). Until then, avoid filing sensitive security issues as public GitHub issues.
