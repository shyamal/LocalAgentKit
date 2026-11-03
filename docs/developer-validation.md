# Independent developer validation

Use this procedure for M1-DC-02 and M1-DC-03. No independent session has been
recorded yet. Maintainer builds and CI results do not satisfy these gates.

## Prepare a session

Recruit a developer who has not seen this repository. Do not send invitations
or share recordings without their consent. Record a participant alias rather
than personal details. Use a clean checkout pinned to a commit; retain the
participant's changes separately from the SDK. Have the participant use the
first-agent and custom-tool guides under `Documentation/`.

Record macOS, hardware, Xcode and Swift versions, checkout commit, prior Swift
experience, existing build caches, network availability and model asset readiness.
Check prerequisites before the timed session. Record prerequisite installation
and asset download time separately; do not silently subtract troubleshooting or
build time once the session starts.

## First-agent task (metric M1)

Ask: “Using the guide, set up and run a local calculator agent. Show the tool's
computed result and explain where the model provider is configured.”

Start the timer at package setup, before cloning or adding the package. Stop when
a successful runtime run and actual calculator result are visible. Retain command
output, elapsed wall time, errors, guide ambiguities and all assistance. Count
build and dependency-resolution time. Do not pause the clock for interventions.
If the participant stops, record an incomplete outcome and elapsed time.

Run the scripted path first to isolate SDK setup. Record it as scripted; its fixed
answer is not evidence of inference. Time the real-model path separately on a
supported Mac with ready assets. A scripted success alone must not close the
real on-device setup claim. A refusal, loop or unavailable model is an unsuccessful
real-model run even if the scripted run passed. The target is strictly under
30 minutes; record raw times rather than rounding a borderline result down.

## Custom-tool task (metric M2)

Ask: “Add an application-owned pure computation tool, register it, and demonstrate
its computed result through the runtime. Explain the permission tier.”

The participant should implement a small conversion different from the supplied
temperature example. They may consult the guide and SDK API documentation. Record
any copied code and assistance. Verify the tool's schema, fixed permission tier,
argument rejection and cancellation behavior. Test actual execution through the
runtime; a fixed final sentence alone is insufficient.

Count all application source required for the demonstration, including imports,
blank lines, schema, registration, event consumption and any scripted model setup.
Exclude the package manifest, tests and SDK source, matching the guide's existing
counting convention. List every counted file and retain `wc -l` output. Success
requires fewer than 100 lines and a working tool; the checked-in 70-line example
is a baseline, not this participant's result. Record manifest and test size
separately so exclusions are visible.

## Result record

Copy this form into a separate session report; leave missing evidence as unknown.
Do not commit secrets, personal calendar contents or identifying recordings.

```text
Participant alias / prior repository exposure:
Date / checkout commit:
Hardware / macOS / Xcode / Swift:
Build cache / network / model asset readiness:
Prerequisite preparation time:
M1 scripted start / finish / elapsed / outcome:
M1 real-model start / finish / elapsed / outcome:
Observed tool result and retained output location:
Errors / assistance / guide changes needed:
M2 custom capability / permission rationale:
M2 counted files / raw wc output / total:
M2 runtime result / validation and cancellation checks:
M2 outcome / assistance / copied code:
Reviewer / evidence reviewed / remaining limitations:
```

A maintainer reviews the evidence against the PRD before updating TASKS.md. Keep
M1-DC-02 or M1-DC-03 in progress if the result is incomplete, assisted by
undocumented steps, over its threshold or lacks retained evidence. Fix the guide
and repeat with another unfamiliar developer after a material setup correction.
This session does not measure model reliability, Core/Runtime test coverage or
provider replacement; those need their own evidence and must not be inferred
from onboarding success.
