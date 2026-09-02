---
name: update-tasks
description: Keep TASKS.md and PLANNING.md accurate after work lands — ticking task IDs, respecting the 🔒 gates, adding IDs for unplanned work, and converting answered open questions into decision records. Use when finishing a task, when asked "what's next", "where are we", "update the tasks", or when a Phase 0 / benchmark result resolves an open question.
---

# Updating project state

`TASKS.md` and `PLANNING.md` are the project's memory — this repo has no code yet, so they are the *only* memory. Stale checkboxes are worse than none: they make the plan look followed when it wasn't.

## Marking tasks

Task IDs are stable and referenced in commits. Never renumber them; append new ones.

`[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked

- Tick `[x]` only when the work meets the definition of done — run the `pr-check` skill first. A partially-done task stays `[~]`.
- Use `[!]` with a one-line reason appended in italics. A blocked task with no stated reason is invisible a week later.
- Commit messages reference the ID: `M1-RT-07: order permission gate after arg validation`.

## Respect the 🔒 gates

Gates aren't decoration — they encode the PRD's "validated, not assumed" principle (§23.13), which exists because v0.1 shipped assumptions that v0.2 had to walk back.

| Gate | Blocks |
|---|---|
| **Phase 0** entirely | All of Milestone 1. No SDK code before the spike reports |
| **P0-03** (real API surface) | Finalizing `Package.swift` |
| **P0-04** (tokenizer access) | `ContextBudgeter` design |
| **P0-13** (refusal detectability) | FR-005 `.refused` design |
| **P0-15** (planner GO/NO-GO) | Which planner is `.default` in v0.1 |
| **M0-13** (layering check) | Should land before there's code to violate it |
| **M3-04** (embedding benchmark) | The rest of the RAG milestone |

If work is proposed that jumps a gate, say so rather than quietly doing it. "The spike hasn't run yet" is the correct answer to "start building the runtime."

## Unplanned work

Work that lands without a task ID becomes invisible to the roadmap. Add an ID in the right milestone using the existing scheme (`M<milestone>-<area>-<nn>`), cite the PRD requirement it serves, and note if it displaced something.

If it serves *no* PRD requirement, that's worth flagging out loud — it may be scope creep, or it may be a gap in the PRD.

## Answered open questions

`PLANNING.md` §6 holds seven open questions. When measurement or SDK verification answers one:

1. Record the answer and the **evidence** — the number, the benchmark, the header you read. "We decided X" without why is unarguable-with later.
2. Move it out of §6 into a decision record (`docs/decisions/`) or the relevant PLANNING section.
3. Update anything downstream that assumed otherwise — an answer that contradicts the architecture means the architecture changes, not the answer.
4. Tick the resolving task (standing obligation C-07).

Don't delete a question silently. A vanished question reads as "never asked."

## Answering "where are we"

Lead with the gate state, not the checkbox count:

1. Which milestone is active, and is it gated on something unfinished?
2. What's `[~]` and what's `[!]` (with reasons)
3. The next 2–3 tasks in dependency order
4. Any open question now blocking progress

Percentages are noise here — 60% of Milestone 1 done means nothing if Phase 0 hasn't reported.

## Milestone completion

Before marking a milestone done, check its **Exit** line, which is a capability claim rather than a task tally. Milestone 1's exit is "the four-turn demo runs end to end on device" — every box ticked with a demo that doesn't run means the boxes were wrong.

Verify metrics claims by measurement:
- M1/M2 (30-minute setup, <100-line tool) — with a developer who hasn't seen the code
- M5–M9 (runtime behavior) — via the FR-029 harness, not informal observation
- M10 (zero network in offline mode) — by traffic capture, not code inspection
