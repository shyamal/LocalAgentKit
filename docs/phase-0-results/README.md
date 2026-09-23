# Phase 0 raw results

Per-run logs behind the rates in [`../phase-0-findings.md`](../phase-0-findings.md), kept so every number there can be re-derived. They are the `P0|` lines the [spike](../../Spike/) prints.

| File | What |
|---|---|
| `p0-09-macos-26.6.2.log` | P0-09 single-tool suite, 20 goals × 5 runs, macOS 26.6.2 |
| `p0-09-ios-27.0.log` | The same on the iPhone 15 Pro, iOS 27.0 (24A435). Merged from three launches because the device connection dropped once: goals st-01–st-09 come from the first launch (its two partial st-10 runs are excluded), and st-10–st-20 come from two re-run batches |
| `p0-10-macos-26.6.2.log` | P0-10 multi-step suite, 10 goals × 5 runs, macOS 26.6.2, catalog as shipped |
| `p0-10-macos-26.6.2-all-required.log` | The same with `--all-required`, the workaround for macOS 26's optional-argument bug (findings §11b) |
| `p0-10-ios-27.0.log` | P0-10 on the iPhone, iOS 27.0, catalog as shipped. Merged from three launches: ms-01–04 from the first (stopped by a >5 min hang in ms-05), then ms-05 and ms-06–10 re-run with the per-run timeout |
| `p0-10-ios-27.0-no-patterns.log` | The same with `--no-patterns`, the workaround for iOS 27's date-JSON bug (findings §11a) |
| `score_p0_10.py` | Completion rate, plus the first reason each failed run failed |
| `p0-11-macos-26.6.2.log` | P0-11 refusal suite, 26 goals × 5 runs, macOS 26.6.2. This is the canonical run: current runner, so every non-refusal error is labelled |
| `p0-11-macos-26.6.2-run1.log` | The first macOS P0-11 run, from a runner build that predates the error-label fix (its `Code=-1` errors are unlabelled). Kept because findings §13 cites it as the repeat of `rf-h06` |
| `p0-11-macos-26.6.2-full-errors.log` | Three goals re-run with `--full-errors`, to read the full text of the `Code=-1` error (findings §13) |
| `p0-11-ios-27.0.log` (complete 2026-09-23) | **Partial**: 57 of 130 runs on the iPhone (iOS 27.0) before the launch stopped at `rf-f05`. Not a verdict; the run has to be redone (as shipped, and with `--no-patterns`) |
| `score_p0_11.py` | Applies decision 0001 to a P0-11 log, typed-only and with soft-refusal flags counted |
| `p0-09-ios-27.0-calendar-no-patterns.log` | P0-09 follow-up: the three calendar goals on iOS 27 with `--no-patterns` (findings §11a) |
| `p0-09-macos-26.6.2-required-no-patterns.log` | P0-09 follow-up: the date goals on macOS 26 with `--all-required --no-patterns` (findings §11a) |
| `score_p0_09.py` | Re-scores a P0-09 log: first call fully correct = schema-valid + right tool + right arguments, with follow-up calls reported separately |

```bash
python3 docs/phase-0-results/score_p0_10.py EvalSuites/phase0/multi-step.json docs/phase-0-results/p0-10-macos-26.6.2.log docs/phase-0-results/p0-10-macos-26.6.2-all-required.log docs/phase-0-results/p0-10-ios-27.0.log docs/phase-0-results/p0-10-ios-27.0-no-patterns.log
```

```bash
python3 docs/phase-0-results/score_p0_09.py docs/phase-0-results/p0-09-macos-26.6.2.log docs/phase-0-results/p0-09-ios-27.0.log
```
