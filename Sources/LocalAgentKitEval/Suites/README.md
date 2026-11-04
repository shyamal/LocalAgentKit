# Phase 0 scenario suites

Scenario data for the FR-029 reliability harness, bundled as resources of the `LocalAgentKitEval` target and loaded by `SuiteLoader`.

**The Phase 0 spike that produced these was throwaway. These files are not** (task P0-18). They moved here from a top-level directory once Phase 0 reported, so they ship with the harness rather than sitting beside it.

What exists today is the data plus enough Swift to load and check it (`swift run LocalAgentKitEval` lists the suites; `Tests/LocalAgentKitEvalTests` keeps them honest). **Running them against a model is task M1-EV-01**; until then the only runner is the throwaway spike in [`Spike/`](../../../Spike/), which bundles these same files.

| File | Task | Contents |
|---|---|---|
| `phase0/tools.json` | shared | The 8 tools the model sees: FR-008 built-ins plus `search_documents` (M1-TL-07), with permission tiers and argument schemas |
| `phase0/single-tool.json` | P0-05 | 20 single-tool goals with known-correct tool and arguments |
| `phase0/multi-step.json` | P0-06 | 10 goals of 3–5 steps: expected steps with a dependency order, fixture tool results, forbidden tools |
| `phase0/refusal.json` | P0-07 | 20 benign health/finance/legal tasks plus 6 paired neutral controls, for the refusal rate |
| `phase0/context-load.json` | P0-08 | A fixture, not goals: conversation with tool traffic, 16 document chunks, plan state, planted-fact probes, and 4 load profiles from 43% to 102% of the context |

Each goal follows the PLANNING §3.5 scenario shape: goal → expected tool → expected arguments → max iterations → permission expectation.

## Design choices a runner must respect

- **Fixed clock.** Goals say "tomorrow" or "Friday afternoon". The suite pins `referenceDateTime` (Monday 2026-09-21 10:00 UTC), and the runner must give that time to the model so every relative date has exactly one right answer.
- **All tools registered for every goal.** Picking the right tool out of the full catalog is part of the measurement, and so is the token cost of 8 tool definitions against a 4096-token context.
- **Matchers, not string equality.** `"0.175 * 2480"` and `"2480*17.5/100"` are both correct, so expressions are scored with `evaluatesTo`. Free-text arguments use `containsAny`/`containsAll`. `absent` catches invented values (st-08 has no due date and must stay that way).
- **Deliberately confusable tools.** `search_files` (names and metadata), `search_documents` (contents) and `search_notes` (notes) overlap on purpose. Goals tagged `disambiguation` measure whether the model tells them apart.

## Multi-step specifics (P0-06)

- **Fixtures are the model's whole world.** Each goal lists canned tool results, picked by argument matchers. Anything unmatched gets `"No results found."`. The one exception is `calculate`: the runner evaluates it for real, because fixturing arithmetic would test nothing.
- **Partial order, not a script.** Steps declare `dependsOn`. Two independent lookups can run in either order, but a step that needs a lookup's result can't come before it.
- **Grounding.** `groundedIn` marks an argument whose correct value only exists in, or is derived from, an earlier tool result: the phone number from a contact card, a date computed from a contract clause. It separates *calling the right tools* from *using what they returned*, and a compact model can pass the first while failing the second.
- **Coverage.** Fan-in (ms-01/03/04), linear chains (ms-02/05/06), a 5-step run mixing permission tiers (ms-07), recovery from an empty result (ms-08), and a conditional both ways. In ms-09 the branch should fire. In ms-10 it shouldn't, and calling `create_note` there fails the goal.
- **Completion (P0-10)** means every required step matched in a dependency-consistent order, no forbidden tool called, no side-effecting tool called more often than expected, and the run stayed within `maxIterations`. Extra read-only calls are allowed but counted.

## Refusal specifics (P0-07)

- **Every goal is benign.** They're ordinary work tasks, like a medication reminder, a revenue calculation, or a plain-English rewrite of a contract clause, that happen to use sensitive wording. A refusal is therefore a false positive, and that's the R3 risk.
- **Paired controls.** Each `control` goal matches a sensitive goal in structure but uses neutral wording (`500 mg tablets` vs. `500 g trays`). A refusal rate alone can't tell "the wording triggered it" from "the model fails this kind of task"; the gap between each pair can.
- **Typed vs. soft refusals are reported separately.** Typed refusals are the framework's `guardrailViolation`/`refusal` errors. Soft ones are text answers that decline, found by marker phrases and confirmed by manual review. Merging them silently would hide which mechanism is firing.
- **Five runs per goal.** Sampling makes refusals nondeterministic; 20 goals × 5 runs is still a coarse rate, and it should be reported as one.
- **Both kinds of goal.** 17 goals are tool calls and 9 are text drafting, because an agent app does both and the guardrails may treat them differently.

## What P0-09 reported

Before P0-09 ran, this section guessed that framework-guided generation would make the literal schema-valid rate "near 100% by construction", and that tool choice and argument values would carry the signal. Measured 2026-09-19 (see `docs/phase-0-findings.md` §11):

- **macOS 26.6.2:** schema-valid 95%, first call fully correct 51%. The guess held here: failures were wrong tools and wrong argument values.
- **iOS 27.0:** schema-valid 71%, first call fully correct 63%. The guess was **wrong** here: every goal with a date-time argument produced JSON the framework couldn't parse.

So runners must report all the measures, not schema validity alone, and must check validity themselves rather than trust the framework.

## Validation

```bash
swift Scripts/validate-eval-suites.swift Sources/LocalAgentKitEval/Suites/phase0
```

This is a structural check that runs in CI. It flags unknown tools or arguments, malformed dates and datetimes, enum violations, `absent` on required arguments, `expectsConfirmation` that contradicts the tool's permission tier, and, for multi-step goals, step counts outside 3–5, `dependsOn` pointing forward, `groundedIn` outside the step's dependency chain, fixtured `calculate`, tools both forbidden and required, `maxIterations` below the step count, for refusal goals, unknown domains, malformed outcomes, and controls not paired with a sensitive goal, and, for the context-load fixture, misnumbered exchanges, tool traffic that doesn't pair up, probes whose fact isn't actually in their source, and profiles larger than the material. It does not run a model.

## Supplemental local notes (M2-09)

`notes/notes-local.json` adds create/search goals without changing the Phase 0
scenario files or their baseline version. Run a synthetic plumbing check with
`swift run LocalAgentKitEval run --suite notes-local --model mock` (the report is
marked synthetic); `--model foundation` requests real on-device model selection.
The probe records model calls and checks schemas; it does not execute note tools
or prove permission enforcement. See NotesCapabilityTests for actual persistence,
approval/denial, invalid arguments, cancellation and adversarial-note coverage.
The catalog already contains create_note/search_notes with their distinct tiers.

## Supplemental local contacts (M2-10)

`contacts/contacts-local.json` adds name/role search goals with sensitive approval
expectations without changing the Phase 0 baseline. Use
`swift run LocalAgentKitEval run --suite contacts-local --model mock` for a synthetic
plumbing check; `--model foundation` probes the on-device model explicitly.
Neither mode reads the device contact store or executes the selected tools.
ContactsToolTests verifies actual approval ordering and backend calls with mocks.
