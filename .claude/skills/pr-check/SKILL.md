---
name: pr-check
description: Run LocalAgentKit's definition-of-done gate before opening a PR or declaring work complete — build under strict concurrency, tests, format, coverage, and the architectural layering check, followed by the review checklist. Use when asked to "check my work", "is this ready to commit", "run the checks", or before any commit or PR on this repo.
---

# Pre-PR check

Run the mechanical checks first, then the judgment checklist. Report what actually happened — a failing check is a finding to surface, not a step to work around.

## 1. Mechanical checks

Run from the repo root, in order. Stop and fix at the first failure rather than collecting them all.

```bash
swift build 2>&1 | tee /tmp/lak-build.log     # must be warning-free under strict concurrency
swift test                                     # full unit suite — no device, no network
swift-format lint --recursive Sources Tests    # CI-enforced formatting
```

### Layering check (the important one)

`Core` and `Runtime` must not import any Apple framework. This is the single check that keeps metric M3 — "replace the model provider without modifying AgentCore" — true a year from now.

```bash
grep -rnE '^import (FoundationModels|CoreAI|SwiftData|Vision|Speech|EventKit|Contacts|SwiftUI)' \
  Sources/LocalAgentKitCore Sources/LocalAgentKitRuntime
```

**Any output is a failure.** Fix it by moving the code into `LocalAgentKitProviders` or `LocalAgentKitTools` — never by adding an exception to the check. If the protocol genuinely can't express what's needed, extend the protocol in Core's own value types.

### Coverage

The 80% gate applies to `LocalAgentKitCore` and `LocalAgentKitRuntime` (metric M4):

```bash
swift test --enable-code-coverage
```

Report the actual number. If it dropped, say by how much and which target.

## 2. Review checklist

From `PLANNING.md` §5 definition of done, plus the standing obligations in `TASKS.md`:

- [ ] **Builds warning-free** under Swift 6 strict concurrency, complete checking — no `@unchecked Sendable`, no warnings silenced
- [ ] **Unit-tested with mocks** — the suite still runs with no device and no network (M1-TS-05)
- [ ] **No new framework imports** in `Core` or `Runtime`
- [ ] **New protocol → new mock** in `LocalAgentKitTesting` (standing task C-06)
- [ ] **New observable state → new `AgentEvent`** (C-03) — if the runtime learned to do something, the UI must be able to see it
- [ ] **New errors are typed** `AgentError` cases, recoverable where possible; **no `fatalError` in library code** (C-04)
- [ ] **No new runtime dependency** without written justification in the PR body (C-05) — the SDK targets zero runtime dependencies
- [ ] **Public API is documented** with DocC comments
- [ ] **Cancellation honored** at every new `await` (FR-024)
- [ ] **Context budget respected** — anything new that enters the prompt goes through `ContextBudgeter`, not around it (R2)

### If the change touches tools or permissions

- [ ] Permission tier justified by "what if a manipulated model called this?", not by normal usage
- [ ] Permission-gate test present for any tier above `.readOnly` (metric M6)
- [ ] Nothing downgrades a tier at runtime

### If the change touches model providers

- [ ] Guardrail refusals map to `.refused` and are **not** retried (R3)
- [ ] Network-capable providers are rejected at construction under `networkPolicy: .never` (FR-023)

## 3. Task hygiene

- [ ] Matching task ID ticked in `TASKS.md`; commit message references it (`M1-RT-07: ...`)
- [ ] Work not on the roadmap has a task ID added rather than landing untracked
- [ ] Any `PLANNING.md` §6 open question this resolved is moved to a decision record (C-07)

## 4. Report

State plainly what passed, what failed, and what you skipped and why. If tests fail, show the output. Don't report completion until the mechanical checks are green — a checklist ticked over a failing build is worse than no checklist.
