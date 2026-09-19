# Phase 0 raw results

Per-run logs behind the rates in [`../phase-0-findings.md`](../phase-0-findings.md), kept so every number there can be re-derived. They are the `P0|` lines the [spike](../../Spike/) prints.

| File | What |
|---|---|
| `p0-09-macos-26.6.2.log` | P0-09 single-tool suite, 20 goals × 5 runs, macOS 26.6.2 |
| `p0-09-ios-27.0.log` | The same on the iPhone 15 Pro, iOS 27.0 (24A435). Merged from three launches because the device connection dropped once: goals st-01–st-09 come from the first launch (its two partial st-10 runs are excluded), and st-10–st-20 come from two re-run batches |
| `p0-10-macos-26.6.2.log` | P0-10 multi-step suite, 10 goals × 5 runs, macOS 26.6.2, catalog as shipped |
| `p0-10-macos-26.6.2-all-required.log` | The same with `--all-required`, the workaround for macOS 26's optional-argument bug (findings §11b) |
| `score_p0_10.py` | Completion rate, plus the first reason each failed run failed |
| `score_p0_09.py` | Re-scores a P0-09 log: first call fully correct = schema-valid + right tool + right arguments, with follow-up calls reported separately |

```bash
python3 docs/phase-0-results/score_p0_10.py EvalSuites/phase0/multi-step.json docs/phase-0-results/p0-10-macos-26.6.2.log docs/phase-0-results/p0-10-macos-26.6.2-all-required.log
```

```bash
python3 docs/phase-0-results/score_p0_09.py docs/phase-0-results/p0-09-macos-26.6.2.log docs/phase-0-results/p0-09-ios-27.0.log
```
