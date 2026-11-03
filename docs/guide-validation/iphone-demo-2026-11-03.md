# iPhone demo check — 2026-11-03

Maintainer-assisted session with the user's paired iPhone (iPhone16,1).
Build based on main a108aea plus the pending calendar planner/demo fixes.
This is a device smoke check, not independent onboarding or harness reliability.

## Observations

- Original calendar question repeatedly called the calendar tool. Stopping the
  third identical read did not resolve the device run: it next hit the eight-step
  limit. Argument variation was not captured, so its precise cause is unproven.
- Updated canonical calendar prompt uses an application-selected workflow with
  literal date bounds computed for tomorrow in the runtime timezone. User
  confirmed it worked and reported no meetings.
- With no meetings available, the tester was directed to search for budget-review
  notes, then create a preparation checklist from those notes. User reported
  completion. This does not demonstrate matching notes to real meeting events.
- Saving prompted for approval. After approval, the user reported the checklist
  was displayed again without an explicit saved-note acknowledgment.
- A targeted read of the app's notes.json found one saved note created at
  10:13 a.m. Asia/Colombo, containing 201 body characters. This establishes a
  persisted write; checklist/body equality was not checked. Raw note content and
  identifiers are not included in this repository.
- After the requested denial check, a second read found one note and byte-equivalent
  decoded note records. No additional write was observed. This depends on the
  user performing the requested denial; UI interaction was not captured directly.

## Persistence follow-up

After the feedback build was installed over the existing app and launched, a
further container read found one saved note. All previously checked records were
preserved and unchanged. This verifies persistence across that update/relaunch;
it does not verify that the saved body equals the generated checklist.

## Remaining checks

The user confirmed that an approved save in the updated app displayed “Saved
note…” with a checkmark. The explicit tool-result feedback display is verified
on the phone.

Still pending: saved-body/checklist comparison,
relevant nonempty calendar-to-notes continuity, and a complete four-turn run with
those conditions. The milestone exit remains pending.

Private device snapshots were kept under /tmp for this local investigation only;
they are not committed as test fixtures.
