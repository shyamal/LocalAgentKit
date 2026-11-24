# M5-08 expanded multi-step evaluation verification

Verified 2026-11-24 using synthetic fixtures and scripted model responses. No new native
model-quality measurement was performed. The M5-03 planner no-go remains unchanged.

## Scenario inventory

| ID | Contract |
| --- | --- |
| mx-01 | Five-step shipment/specification/calculation/note/reminder chain |
| mx-02 | Workshop room/contact fan-in before a grounded note |
| mx-03 | Above-limit estimate triggers a grounded note |
| mx-04 | Below-limit estimate forbids writes; comparison calculation is optional |
| mx-05 | Empty note search falls back to document contents before saving |
| mx-06 | Onboarding document contains an unwanted instruction; reminder/contact calls fail the contract |
| mx-07 | Grounded incident note followed by a distinct confirmed reminder |
| mx-08 | File discovery, content search, arithmetic and grounded note |

The suite uses the existing eight-tool catalog and fixed UTC clock. Expected matcher
values stay in routing/scoring, not prompts. Only fixture backends run; calculator
expressions are evaluated locally. Auto-approval is private to fixture tools. The suite
cannot access the user's contacts, calendar, documents, notes or reminders.

## Reports and baseline protection

Select `--suite multi-step-extended` with either `--planner state-machine` or
`--planner model-driven`. Goal filtering, limits, repetition bounds, timeouts and
cancellation use the existing runner. All selected contracts are preflighted before work.

Supplemental reports use schema 1, mode `expanded-agent-run`, suite
`m5-expanded-multi-step`, version 1. They retain raw requested/completed calls, scores,
planner, model, clock, OS, timing and repetition metadata, but contain no M5 assessment.
The original Phase 0 JSON files and schema-3 report format are unchanged. Historical
M5 replay remains baseline-only; supplemental results must not be pooled into its rate.

## Checks

- Nine new test functions cover eight reference traces, deletion of every required call,
  independent fan-in ordering, wrong grounded writes, forbidden actions, optional
  comparison, repeated confirmed writes, fixture runtime integration and option rejection.
- Full/offline suites: 893 registered functions passed.
- Thread Sanitizer: 10 supplemental and retained-baseline functions passed without reported races.
- Baseline validator: 56 goals; supplemental validator: eight goals, both against eight tools.
- CLI smoke reports validated for both planners: eight synthetic incomplete results each,
  no M5 assessment field. These are plumbing checks, not successful model trials.
- Original baseline CLI smoke still emits schema 3 with its M5 assessment.
- Warning-free build, strict changed-file formatting, layering and whitespace checks passed.
- DocC build and static routes passed: six modules, 11,249 internal references.
- Core: 99.80% (992/994); Runtime: 98.52% (2939/2983).
- Combined: 98.84% (3931/3977), down 0.05 percentage points from M5-06;
  Core unchanged, Runtime down 0.07. No Core or Runtime source changed in this task.

## Limits

These scenarios measure ordered tool-argument grounding, not semantic answer correctness,
parallel overlap or real-device tool permissions. The untrusted-document scenario is a
behavioral probe, not proof of injection resistance. The paired conditional goals and
held-out facts are fixed public fixtures, not an independent held-out benchmark. Native
completion/refusal/latency rates remain unmeasured. Deliberate loop scenarios and metric
M8 verification remain M5-09.
