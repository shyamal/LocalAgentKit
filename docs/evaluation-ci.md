# Release and installed-beta evaluation

M1-EV-07 adds `.github/workflows/evaluation.yml` and `Scripts/eval_ci.py`.
The workflow is prepared and locally tested. **It is not activated or verified on
GitHub:** the repository runner inventory was empty on 2026-10-24, and these
changes have not been pushed. M1-EV-07 remains in progress until live stable and
beta runner jobs produce and compare their artifacts.

## Provision the runners

Use two dedicated, native Apple-silicon Macs: one on the supported stable macOS,
one on the beta to measure. Each needs Apple Intelligence enabled, the model
available, Xcode capable of building the package, GitHub CLI (`gh` with
`api --paginate --slurp` and `run download`), and Python 3.9 or later. Verify a
FoundationModelProvider evaluation manually under the same logged-in user that
will run the runner. A simulator or merely selecting a beta SDK does not measure
a beta OS model. This workflow covers Mac hosts; physical-iPhone measurements
remain separate.

Register runners using the repository's
[runner settings](https://github.com/shyamal/LocalAgentKit/settings/actions/runners).
Keep the default `self-hosted`, `macOS`, `ARM64` labels and add exactly one channel
label per host:

- `localagentkit-model-stable`
- `localagentkit-model-beta`

Run one Actions runner per physical evaluation Mac so model jobs execute serially.
Do not share these persistent runners with pull-request jobs or personal-data
workflows. This workflow has no PR trigger, manual runs use the default branch,
and releases use the published tag. Checkout credentials are not persisted; the
workflow token has only contents/actions read permission and is passed only to
baseline discovery. No account-wide token is required.

After this workflow and harness are on the default branch, configure repository
Actions variables:

| Variable | Value |
|---|---|
| `LOCALAGENTKIT_EVAL_ENABLED` | `true` after both runners are ready; absent/false skips the job |
| `LOCALAGENTKIT_STABLE_DEVELOPER_DIR` | Optional absolute `Xcode.app/Contents/Developer` path on the stable host |
| `LOCALAGENTKIT_BETA_DEVELOPER_DIR` | Optional corresponding beta Xcode path; otherwise the runner's selected Xcode is used |
| `LOCALAGENTKIT_EVAL_FAIL_ON_REGRESSION` | Optional `true` to fail on any adverse comparable observation, including latency variation; absent means report-only drift |

No runner service, repository setting, OS update, or workflow dispatch is created
by the local implementation work. Registration and activation remain outstanding.

## Triggers and beta update procedure

Published releases (including published prereleases) run stable and beta channels.
Manual dispatch selects `both`, `stable`, or `beta`, and always checks out the
default branch. The daily 05:23 UTC schedule checks the beta host and skips only
when its last complete run was not failed and OS build, source revision and Xcode
are unchanged. Failed runs are retried on the next scheduled check.

After installing **each** beta, dispatch `os-beta-installed` with the actual
`sw_vers -buildVersion` result. For example, save this payload with the real build
in `/tmp/beta-event.json`:

```json
{
  "event_type": "os-beta-installed",
  "client_payload": { "os_build": "<installed-build>" }
}
```

```bash
gh api --method POST repos/shyamal/LocalAgentKit/dispatches --input /tmp/beta-event.json
```

The installed build must match the payload before measurement; mismatches fail.
The daily check is a fallback for missed dispatches, not an Apple beta-release
feed or an installer. It cannot measure a beta that was never installed, or one
replaced before its job runs. Keep each beta installed until its measurement
finishes. Event semantics follow
[GitHub's workflow trigger documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).

## Evidence and baseline selection

Each channel uploads `localagentkit-eval-<channel>` for 90 days, even when build or
measurement fails after preparation. It contains:

- Four full raw suite reports, command logs, and any comparison JSON/logs.
- Refusal review templates with unresolved decisions; automation never supplies a human decision.
- `manifest.json`: OS version/build, Xcode, architecture, source revision, runner,
  event/run/attempt, baseline run, expected trial counts and individual exit codes.
- `summary.md`, also published to the job summary, with aggregate deltas and warnings.

The full protocol is 60 single-tool trials (three repetitions), 30 multi-step
trials (three), 130 refusal trials (five), and 144 context trials (three, both
modes). Single-call/context/refusal goals use 20-second limits; multi-step goals
use 60 seconds. Each suite also has a process deadline, and the job has a
180-minute limit. One failing suite does not suppress later suites. Only fixture
tools execute, never the user's calendar, reminders or note store.

Baseline discovery uses GitHub's
[artifact API](https://docs.github.com/en/rest/actions/artifacts) and `gh run download`.
It selects the newest nonexpired artifact in the same channel from a completed,
same-repository run of this exact workflow, excluding PR/foreign workflows and
the current run. The manifest must mark it live/complete and its reports must
have the declared unique trial counts. Incomplete artifacts are retained for
inspection but never promoted to a baseline. Baseline downloads live outside the
uploaded directory so artifacts do not recursively contain prior runs.

`complete` means complete **raw evidence**, not successful goals. Runs with model
errors can be complete and still fail the job. API/download errors fail discovery
rather than masquerading as a first run. With no eligible retained baseline, the
summary says `no-baseline (bootstrap; no drift verdict)`; that is not a drift pass.
Expired artifacts may require a new bootstrap measurement.

Comparison uses the EV-06 protocol checks. Provisional/incompatible comparisons,
missing/invalid reports, deadlines, nonzero suite exits (including M9 failures or
pending reviews), and opt-in observed regressions fail the job after preserving
evidence. Normal drift is descriptive by default. The optional drift exit has no
statistical significance threshold, so it is unsuitable as a silent M5 release
gate. M5 integration remains M1-EV-08. Hardware/source metadata provides context,
not an isolation of OS effects; no causal attribution is made.

## Local verification

```bash
python3 -m unittest discover -s Scripts/tests -p 'test_eval_ci.py'
actionlint .github/workflows/evaluation.yml .github/workflows/ci.yml
swift build
python3 Scripts/eval_ci.py run --cli "$(swift build --show-bin-path)/LocalAgentKitEval" --output /tmp/eval-ci-smoke --smoke
python3 Scripts/eval_ci.py run --cli "$(swift build --show-bin-path)/LocalAgentKitEval" --output /tmp/eval-ci-compare-smoke --baseline /tmp/eval-ci-smoke --smoke
```

Smoke reports are synthetic and cannot become live baselines. Twelve offline
orchestration tests cover installed-build changes, skip/retry behavior, artifact
selection, incomplete/foreign/PR evidence, API failures, expected-build mismatch,
continued execution, process deadlines, missing reports, provisional comparisons
and avoiding recursive uploads. The normal CI workflow runs those tests on its
hosted runner; no model-capable host is needed for them.


Local verification on 2026-10-24 passed: actionlint for both workflows, all 12
orchestration tests, synthetic four-suite collection and four comparisons,
warning-free Swift build, all 434 default Swift tests (also under socket-network
denial), strict Swift format lint and layering. Core coverage was 99.77%
(438/439), Runtime 98.41% (1483/1507), combined 98.72% (1921/1946).
These are local checks, not proof that the GitHub runner setup works.


## M5 integration

M1-EV-08 adds `multi-step-m5.json`/`.log` to each batch, with a summary row and
`m5ExitCode`. Assessment replays the collected report and never calls the model.
Below-target, partial, no-attempt, missing-coverage and fixture-only unverified
live assessments fail the batch; synthetic smoke assessments remain explicitly
synthetic. The real-device M5 success target is not verified by fixture evidence.
See [M5 evidence semantics](evaluation-harness.md#continuous-m5-evidence-m1-ev-08).
The orchestration suite now includes a thirteenth test proving that an M5 failure
fails an otherwise successful batch while preserving all raw suite reports.
Activation of the release/beta workflow remains pending.
