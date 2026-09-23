# 0002: `StateMachinePlanner` is the v0.1 default

**Status:** Accepted, 2026-09-23 — this is the P0-15 GO/NO-GO
**Relates to:** PRD R1, FR-026, FR-027, metric M5; PLANNING §2.4; tasks P0-09, P0-10, M1-RT-11, M1-RT-12, M5-03

## Context

PLANNING §2.4 ships two planners behind one `AgentPlanner` protocol and left the default to Phase 0:

- **`StateMachinePlanner`** — deterministic control flow; the model is consulted for *individual* decisions. "Robust, dull, and always shippable."
- **`ModelDrivenPlanner`** — the model emits and revises a whole plan. More capable, unproven on-device.

The PRD pre-committed the rule (§21 Phase 0, task P0-15): **below the >95% M5 bar it is the state machine, and that is a successful, shippable outcome, not a failure.** This decision applies that rule to the measurements; it is not a fresh judgement call.

## Evidence

Measured on macOS 26.6.2 and a physical iPhone 15 Pro (iOS 27.0). Details in `docs/phase-0-findings.md` §11–§14; raw logs in `docs/phase-0-results/`.

| | macOS 26 | iOS 27 | Bar |
|---|---|---|---|
| P0-09: first tool call fully correct | 51% | 63% | >95% |
| P0-10: 3–5 step task completed end to end | 14% (28% with the OS's framework bug worked around) | 14% (20%) | >95% |
| P0-12: facts present in the window that reached the answer | 55% | 100% | — |

Not marginal: the best multi-step figure on either host is **28% against a 95% bar**. Even a hypothetical fix for every framework bug would have to roughly triple end-to-end completion.

**What fails matters more than the rate.** Once each OS's framework bug is worked around, the largest model-side failure class in P0-10 is **grounding**: the right tool is called, but a value from an earlier tool result (a phone number, a tip, an email address, a computed deadline) does not carry into the next call. Skipped steps, wrong dates, and repeated side-effecting calls follow. Conditional logic works in one direction (the branch that should fire did, 5/5 and 4/5) and fails in the other (the branch that should *not* fire did anyway, 4/5).

## Decision

**`StateMachinePlanner` is `.default` in v0.1.** `ModelDrivenPlanner` still ships (M1-RT-12) and stays selectable by configuration, exactly as §2.4 intended.

## Consequences

- **The runtime carries state between steps in code, not in the model's head.** Grounding is the dominant failure, and it is the one thing a deterministic planner removes by construction: values flow through `AgentContext`, and the model is asked one narrow question per step.
- **Per-step questions must assume ~50–60% single-call accuracy** (P0-09). The state machine has to validate every answer it gets, retry with a narrower question, and prefer closed choices ("which of these tools?") over free-form argument generation wherever possible. `ToolExecutor`'s argument validation is load-bearing (findings §11).
- **Conditional guards belong in the planner, not the prompt.** The model acted on a goal's verb rather than checking its condition (P0-10 ms-10). Thresholds and "only if" rules are evaluated in code.
- **Repeated side effects need runtime protection.** The model created duplicate notes in 22 of 50 iOS runs; the executor should detect repeated identical side-effecting calls rather than rely on the model not making them.
- **FR-026/FR-027 (planning, replanning) are not MVP-blocking as model-driven features.** Deciding whether they are deferred outright is P0-17, which this decision unblocks.
- **Revisit rather than re-litigate.** M5-03 already requires re-running these measurements before `ModelDrivenPlanner` is promoted. The threshold for revisiting is the same >95% M5 bar on the same suites, measured per OS version (behaviour differs by OS everywhere in Phase 0, and Apple can change the model in any update — R4).

## Note

This decision follows the rule the PRD set before the data existed, which is why it is recorded without a fresh debate. The owner can overrule it, but doing so means shipping a default that completes roughly one multi-step task in four.
