# Four-turn iPhone acceptance check

This is the Milestone 1 device exit check, not a substitute for the FR-029
reliability harness or independent developer metrics. Record observations, not
just the model's claim that an action succeeded.

## Before running

Record the commit, iPhone model, iOS version, Xcode version and date. Build the
main `LocalAgentDemo` target for a physical Apple Intelligence-capable iPhone,
with model assets ready. Keep existing app data; do not uninstall or reset
permissions to prepare this check. Calendar access needs the person's approval.
Do not add or alter calendar events without their permission.

Use one uninterrupted conversation for turns 1–4. The bundled notes describe a
budget review, project sync and onboarding. If tomorrow's actual calendar has
no related meetings, record that limitation; do not count unrelated retrieval
as a semantic match. Screenshots or transcripts may contain private information;
keep evidence local and redact before sharing.

## Observe each turn

| Turn | Input | Evidence required |
| --- | --- | --- |
| 1 | What meetings do I have tomorrow? | Calendar tool activity and answer agree with the authorized calendar. An empty day is a valid observation, but cannot demonstrate matching meeting notes. |
| 2 | Find my notes related to those meetings. | Document search returns bundled content; answer distinguishes relevant notes from no matching results. No loop or context-limit failure. |
| 3 | Create a preparation checklist. | Checklist uses earlier meetings/notes where available and does not claim unsupported details. Retain the checklist for comparison with the saved note. |
| 4 | Save that as a note. | A create-note confirmation appears before any write. Inspect title/body, approve only the intended content, and observe the saved-note tool result. |

A final sentence saying “saved” is insufficient: confirm the actual stored note
contains the checklist. In Xcode Devices and Simulators, download the app's data
container and inspect `Library/Application Support/LocalAgentDemo/notes.json`
locally. Retain only a redacted comparison or count/identifier evidence. A newly
saved note should remain in that file after relaunch; conversation history need
not persist in this milestone.

## Denial check

After the four-turn check, ask to save another note, inspect the confirmation,
and deny it. Compare the stored note count before and after: it must not change.
Record any refusal or failed run as such. Do not bypass the confirmation or
install an always-approve gate to obtain a passing result.

## Session record

```text
Commit / build date:
iPhone / iOS / Xcode:
Apple Intelligence readiness / calendar authorization:
Turn 1 calendar observations:
Turn 2 retrieved content and relevance:
Turn 3 checklist continuity:
Turn 4 confirmation / approval / actual stored content:
Relaunch persistence:
Denial check before/after note count:
Errors, refusals, loops or context limits:
Evidence location (local/redacted):
Outcome: pass / fail / incomplete
```

Keep the milestone exit pending until the full device sequence and permission
behavior have retained evidence. Prior confirmation that turn 2 found notes
establishes retrieval only; it does not establish turns 3 and 4.
