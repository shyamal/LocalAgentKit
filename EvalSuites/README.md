# Eval suites

Scenario data for the Phase 0 feasibility spike and, later, the `LocalAgentKitEval` reliability harness (FR-029). **The spike code is throwaway. These files are not** (task P0-18): they will move into the `LocalAgentKitEval` target as resources.

They live at the repo root rather than inside `Sources/LocalAgentKitEval/` for now because SwiftPM warns about unhandled files in a target directory, which would break the warning-free build gate. Declaring them as resources in `Package.swift` is P0-18's job.

| File | Task | Contents |
|---|---|---|
| `phase0/tools.json` | shared | The 8 tools the model sees: FR-008 built-ins plus `search_documents` (M1-TL-07), with permission tiers and argument schemas |
| `phase0/single-tool.json` | P0-05 | 20 single-tool goals with known-correct tool and arguments |

Each goal follows the PLANNING §3.5 scenario shape: goal → expected tool → expected arguments → max iterations → permission expectation.

## Design choices a runner must respect

- **Fixed clock.** Goals say "tomorrow" or "Friday afternoon". The suite pins `referenceDateTime` (Monday 2026-09-21 10:00 UTC), and the runner must give that time to the model so every relative date has exactly one right answer.
- **All tools registered for every goal.** Picking the right tool out of the full catalog is part of the measurement, and so is the token cost of 8 tool definitions against a 4096-token context.
- **Matchers, not string equality.** `"0.175 * 2480"` and `"2480*17.5/100"` are both correct, so expressions are scored with `evaluatesTo`. Free-text arguments use `containsAny`/`containsAll`. `absent` catches invented values (st-08 has no due date and must stay that way).
- **Deliberately confusable tools.** `search_files` (names and metadata), `search_documents` (contents) and `search_notes` (notes) overlap on purpose. Goals tagged `disambiguation` measure whether the model tells them apart.

## What P0-09 should report

Foundation Models constrains tool arguments to the tool's `GenerationSchema` during decoding. So the literal P0-09 metric, the *schema-valid* argument rate, is expected to sit near 100% by construction. That's a hypothesis to measure, not a result. The rates that actually separate a capable planner from a weak one are likely to be **`toolCorrect`** (right tool) and **`argumentsCorrect`** (right values), so the runner should report all of them, not just schema validity.

## Validation

```bash
swift Scripts/validate-eval-suites.swift EvalSuites/phase0
```

This is a structural check that runs in CI. It flags unknown tools or arguments, malformed datetimes, enum violations, `absent` on required arguments, and `expectsConfirmation` that contradicts the tool's permission tier. It does not run a model.
