# Contributing to LocalAgentKit

## Before you start

This project is pre-alpha — see [`README.md`](./README.md) for current status. Two things matter more here than in most repos:

1. **Check [`TASKS.md`](./TASKS.md) first.** Work is tracked as task IDs (`M1-RT-07`) grouped into milestones. If what you want to build already has an ID, use it. If it doesn't, add one in the right milestone before opening a PR — untracked work is invisible to the roadmap.
2. **Respect the 🔒 gates.** Phase 0 has reported; Milestone 1 is active. Keep remaining measurement and release gates explicit — see [`PLANNING.md`](./PLANNING.md) §5 for why, and [`CLAUDE.md`](./CLAUDE.md) for the current gate list. If you think a gate should be crossed, say so in an issue rather than doing it in a PR.

LocalAgentKit is licensed under the [Apache License, Version 2.0](LICENSE).
Contributions intentionally submitted for inclusion are covered by its contribution
terms unless explicitly stated otherwise or governed by a separate agreement. CI workflow definitions are present; verify actual hosted results on each PR before treating them as evidence.

## Prerequisites

- Apple silicon Mac, Xcode 27 SDK and Swift 6.2+; runtime deployment remains iOS/macOS 26.4+
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

## CI toolchain

Primary CI and DocC use GitHub's `xcode-27` hosted image and its selected default
Xcode, rather than selecting an unverified installation path. The image is listed
in [GitHub runner-images](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).
`Scripts/check-ci-toolchain.py` requires Xcode/SDK 27 and Swift 6.2+, plus macOS 27
so the asset-free LanguageModel adapter tests execute instead of skipping. This is
a CI host requirement, not an increase to the library deployment floor.

A macOS 26.4+ development machine with the Xcode 27 SDK can still build and run
supported paths. Its OS 27 tests skip locally; use the documented simulator helper
for those tests. Running the CI preflight on such a machine deliberately fails the
host check. Hosted workflow execution remains separate validation after changes
are pushed; local tests do not prove the hosted image or job succeeded.
