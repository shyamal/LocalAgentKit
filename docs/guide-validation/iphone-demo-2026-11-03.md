# iPhone demo check — 2026-11-03

Latest outcome: **device acceptance passed**, based on the user-confirmed final
sequence and targeted persistence check below. Earlier failures are retained as
investigation evidence; they are superseded by the final acceptance result.

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

## Nonempty-calendar follow-up

The tester added a Budget review meeting for tomorrow and confirmed the app
reported it at the correct time. The canonical related-notes prompt then hit
the eight-step limit, so the complete four-turn sequence did not pass.

The demo now uses a preselected single-search workflow for that exact notes
prompt: extract a query from recent meeting context, execute search once, then
answer from results. Empty results skip retries and still produce an answer.
Two tests compile the actual app setup source and drive DemoPlanner through the
runtime with scripted models, checking meeting history, one search, and empty
results. The iPhone build succeeds. Real-device retrieval after this fix remains
pending; no reliability claim is inferred from scripted tests.

## Checklist follow-up

The user confirmed retrieval found Budget review notes after the single-search
fix. The checklist prompt then reached the eight-step limit. The demo now routes
its canonical checklist prompt to a preselected response-only workflow. A test
asserts one answer request with prior meeting/note context, no offered tools and
zero search/save executions. Physical checklist completion after this fix is
still pending.

## Saved-content follow-up

The user reported checklist creation and an approved save with a checkmark. A
fresh container read found three notes, two newer than the earlier baseline. The
latest body was 79 characters and reported that no meetings were identified,
rather than containing the expected Budget review preparation. This is a failed
content check despite successful persistence/feedback. The user confirmed they
had repeated calendar and note retrieval after restart.

The planner's answer prompt previously clipped each earlier message to 200
characters. It now passes prior text as separate messages through the existing
budgeter, preserving recent details until actual token fitting. This removes a
confirmed truncation boundary; it does not prove truncation was the sole cause of
the device result. Tests place useful note details beyond 200 characters.

For the canonical save prompt, the demo now supplies the completed checklist
body as a literal tool argument, with no model reconstruction or truncation. The
runtime permission gate still governs execution. Tests compare the full long body
at the gate and executed tool, verify denial blocks the write, and verify a missing
completed checklist cannot be saved. Real-device content fidelity after these
changes remains pending. Raw device notes are not committed.

## Calendar-result follow-up

The next device retry reported no meetings even though the tester confirmed
Budget review was still listed tomorrow in Calendar. The actual tool result and
device clock were not captured, so the cause remains unproven. devicectl details
exposed no direct device-clock/timezone field.

The canonical calendar turn now returns the calendar observation directly,
without a model summary. It includes the queried local date/timezone and formats
structured event times locally. Regression tests cover empty/nonempty results,
zero model calls, Colombo date boundaries and a 25-hour daylight-saving day.
This distinguishes an empty EventKit result from an incorrect generated summary;
physical verification after the change is still pending.

## Direct-retrieval follow-up

The user confirmed the corrected direct calendar display showed Budget review
at the correct time. The next notes turn reported no notes. There is no captured
tool output from that run, so empty ingestion/retrieval and an incorrect generated
summary cannot yet be distinguished.

The canonical notes workflow now displays the actual search query and tool result
without a model summary. Tests require exactly one model request (query extraction),
one search, preserved nonempty passage text, and explicit empty-result text. Ranked
passages are not claimed to be semantically relevant just because they were
returned. Device retrieval after this change remains pending.

## Routing diagnosis pending

The user reported another eight-step error for the exact canonical notes prompt.
The actual-source regression passes with maxIterations set to two and asserts two
iterations, one query-generation request and one search. The discrepancy is not
resolved by that test alone.

A debug-app-only, overwritten local plan snapshot now records the build marker,
submitted goal, selected workflow and plan step IDs. It excludes conversation and
tool result contents, is not generated by SwiftPM tests or release builds, and is
intended to distinguish device routing/build issues on the next reproduction.
The diagnostic marker was verified in the built iPhone binary before installation.
The snapshot itself is not a repository fixture. Diagnosis remains pending.

## Final acceptance

On the latest diagnostic build, the user confirmed notes were found, the checklist
was created, and the note was saved correctly. This follows their confirmation of
Budget review at the correct time in the direct calendar output. The user had
been asked to compare the checklist and approval body before approving the save.

A targeted container read then found four saved records. The latest body was
582 characters and contained Budget review, Priya and headcount details; it did
not contain the earlier incorrect no-meetings statement. This corroborates the
reported successful write and relevant content. Exact equality to the on-screen
checklist is user-confirmed rather than independently captured from the UI;
scripted approval/denial tests compare long checklist bodies exactly at the gate
and executed tool.

The overwritten diagnostic showed build bounded-notes-2026-11-03-v4, workflow
save_checklist and step save. It establishes that final routing, but does not
retroactively explain the earlier eight-step device report. The temporary
recording code was removed after this check; raw device snapshots are not
committed. The tested final functional changes remain intact.

The canonical device demo acceptance is complete. This does not establish a
statistical model reliability rate, independent developer metrics, every wording
variation, or stable/beta runner operation. Those milestone gates remain open.

## Final verification after diagnostic removal

Seven demo test functions (including parameterized calendar and permission cases),
full default suite, offline suite, Swift package build, physical-iPhone build,
31 Python tests, strict formatting, layering and actionlint pass. Core/Runtime
line coverage is 98.35% (2261/2299). The first final coverage attempt stalled in
Xcode's swiftpm-testing-helper; an idle process sample was retained locally, the
owned run was terminated, and one retry of the same gate passed. The stalled run
is not counted as successful. No inference about the precise runner-stall cause
is made from the sample. Device acceptance was observed before debug-recording
removal; the cleanup removes only diagnostic I/O, and the cleaned source builds.
