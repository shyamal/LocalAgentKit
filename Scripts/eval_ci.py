#!/usr/bin/env python3
"""Run FR-029 suites and retain drift evidence. Standard library only; no model APIs here."""
import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

SUITES = {"single-tool": (3, 20, 1320), "multi-step": (3, 60, 1920),
          "refusal": (5, 20, 2720), "context-load": (3, 20, 3000)}
WORKFLOW = ".github/workflows/evaluation.yml"


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def read_json(path):
    return json.loads(path.read_text())


def command_output(command):
    return subprocess.check_output(command, text=True, timeout=60).strip()


def provenance(channel):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("Live evaluation requires a native Apple-silicon Mac.")
    build = command_output(["sw_vers", "-buildVersion"])
    expected = os.environ.get("EXPECTED_OS_BUILD", "")
    if expected and build != expected:
        raise ValueError(f"Expected OS build {expected}, found {build}; install it before dispatch.")
    return {"schemaVersion": 1, "channel": channel, "osBuild": build,
            "osVersion": command_output(["sw_vers", "-productVersion"]),
            "architecture": platform.machine(), "runner": os.environ.get("RUNNER_NAME", "local"),
            "xcode": command_output(["xcodebuild", "-version"]),
            "sourceRevision": command_output(["git", "rev-parse", "HEAD"]),
            "runID": os.environ.get("GITHUB_RUN_ID"),
            "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "event": os.environ.get("GITHUB_EVENT_NAME", "local"),
            "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "synthetic": False, "complete": False}


def gh_json(endpoint):
    return json.loads(command_output(["gh", "api", endpoint]))


def baseline_candidates(pages, channel, current_run):
    name = f"localagentkit-eval-{channel}"
    return sorted((artifact for page in pages for artifact in page["artifacts"]
                   if artifact["name"] == name and not artifact["expired"]
                   and str(artifact["workflow_run"]["id"]) != str(current_run)),
                  key=lambda artifact: artifact["created_at"], reverse=True)


def find_baseline(repo, channel, current_run, destination):
    # Only this workflow's completed, same-repository, non-PR runs are eligible.
    endpoint = f"repos/{repo}/actions/artifacts?name=localagentkit-eval-{channel}&per_page=100"
    pages = json.loads(command_output(["gh", "api", "--paginate", "--slurp", endpoint]))
    for artifact in baseline_candidates(pages, channel, current_run):
        run_id = str(artifact["workflow_run"]["id"])
        run = gh_json(f"repos/{repo}/actions/runs/{run_id}")
        if (run["status"] != "completed" or run["path"] != WORKFLOW
                or (run.get("head_repository") or {}).get("full_name") != repo
                or run["event"] not in {"release", "workflow_dispatch", "repository_dispatch", "schedule"}):
            continue
        target = destination / run_id
        target.mkdir(parents=True)
        subprocess.run(["gh", "run", "download", run_id, "--repo", repo,
                        "--name", artifact["name"], "--dir", str(target)], check=True, timeout=120)
        manifest_path = target / "manifest.json"
        if not manifest_path.is_file():
            continue
        manifest = read_json(manifest_path)
        if (manifest.get("complete") is True and manifest.get("synthetic") is False
                and manifest.get("channel") == channel
                and isinstance(manifest.get("expectedTrials"), dict)
                and not report_errors(target, manifest["expectedTrials"], False)):
            return target, manifest
    return None, None


def should_run(event, current, previous):
    return event != "schedule" or previous is None or previous.get("jobFailed", False) or any(
        current.get(key) != previous.get(key) for key in ("osBuild", "sourceRevision", "xcode"))


def prepare(args):
    args.output.mkdir(parents=True, exist_ok=False)
    current = provenance(args.channel)
    write_json(args.output / "manifest.json", current)
    baseline, previous = find_baseline(args.repo, args.channel, args.run_id, args.output.with_name(args.output.name + "-baselines"))
    run = should_run(os.environ.get("GITHUB_EVENT_NAME"), current, previous)
    current["baselineRunID"] = previous.get("runID") if previous else None
    current["skippedUnchanged"] = not run
    write_json(args.output / "manifest.json", current)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"should_run={'true' if run else 'false'}\n")
        output.write(f"baseline={baseline or ''}\n")
    if not run:
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write("Evaluation skipped: installed OS build, source and Xcode are unchanged.\n")


def execute(command, log, timeout):
    with log.open("w") as output:
        try:
            return subprocess.run(command, stdout=output, stderr=subprocess.STDOUT,
                                  timeout=timeout, check=False).returncode
        except subprocess.TimeoutExpired:
            output.write("\nHarness process deadline exceeded; evidence may be incomplete.\n")
            return 124


def expected_trials(suite, smoke):
    corpus = Path(__file__).resolve().parents[1] / "Sources/LocalAgentKitEval/Suites/phase0"
    fixture = read_json(corpus / f"{suite}.json")
    if suite == "context-load":
        return len(fixture["profiles"]) * (1 if smoke else len(fixture["probes"])) * 2 * (1 if smoke else SUITES[suite][0])
    return 1 if smoke else len(fixture["goals"]) * SUITES[suite][0]


def report_errors(directory, expected, synthetic):
    errors = []
    for suite in SUITES:
        try:
            report = read_json(directory / f"{suite}.json")
            results = report["results"]
            if (report.get("synthetic") is not synthetic or not isinstance(results, list)
                    or len(results) != expected[suite]):
                raise ValueError("wrong mode or trial count")
            keys = [(r["profileID"], r["toolMode"], r["probeID"], r["repetition"])
                    if suite == "context-load" else (r["goalID"], r["repetition"]) for r in results]
            if len(set(keys)) != len(keys):
                raise ValueError("duplicate trials")
        except (OSError, ValueError, KeyError, TypeError) as error:
            errors.append(f"{suite}: incomplete or invalid evidence ({error})")
    return errors


def batch(args):
    if args.baseline and args.output.resolve() == args.baseline.resolve():
        raise ValueError("Output directory must differ from the baseline directory.")
    args.output.mkdir(parents=True, exist_ok=True)
    manifest_path = args.output / "manifest.json"
    manifest = read_json(manifest_path) if manifest_path.exists() else {}
    if not args.smoke and not manifest:
        raise ValueError("Live batches require prepare provenance first.")
    manifest.update({"schemaVersion": 1, "synthetic": args.smoke, "complete": False,
                     "suiteExitCodes": {}, "comparisonExitCodes": {}, "m5ExitCode": None})
    manifest["expectedTrials"] = {suite: expected_trials(suite, args.smoke) for suite in SUITES}
    write_json(manifest_path, manifest)
    summary = ["# Evaluation drift report", "", "Synthetic smoke only." if args.smoke else
               f"Channel: {manifest['channel']}; OS build: {manifest['osBuild']}; source: {manifest['sourceRevision']}.",
               "", "| Suite | Run exit | Comparison |", "|---|---:|---|"]
    failed = False
    for suite, (repetitions, timeout, process_timeout) in SUITES.items():
        path = args.output / f"{suite}.json"
        path.unlink(missing_ok=True)
        (args.output / f"{suite}-comparison.json").unlink(missing_ok=True)
        if suite == "refusal":
            (args.output / "refusal-reviews.json").unlink(missing_ok=True)
        command = [str(args.cli), "run", "--model", "mock" if args.smoke else "foundation",
                   "--suite", suite, "--repetitions", str(1 if args.smoke else repetitions),
                   "--timeout", str(timeout), "--output", str(path)]
        if args.smoke:
            command += ["--limit", "1"]
        if suite == "refusal":
            command += ["--review-template", str(args.output / "refusal-reviews.json")]
        code = execute(command, args.output / f"{suite}.log", process_timeout)
        manifest["suiteExitCodes"][suite] = code
        failed |= code != 0
        status = "no-baseline (bootstrap; no drift verdict)"
        if args.baseline:
            old = args.baseline / f"{suite}.json"
            comparison = args.output / f"{suite}-comparison.json"
            if old.is_file() and path.is_file():
                command = [str(args.cli), "compare", "--baseline", str(old), "--candidate", str(path),
                           "--output", str(comparison)]
                if args.fail_on_regression:
                    command.append("--fail-on-regression")
                compare_code = execute(command, args.output / f"{suite}-comparison.log", 60)
                manifest["comparisonExitCodes"][suite] = compare_code
                failed |= compare_code != 0
                status = f"exit {compare_code}"
                if comparison.is_file():
                    result = read_json(comparison)
                    status = f"{result['status']}; observed regression: {result['observedRegression']}"
                    for note in result.get("reasons", []) + result.get("warnings", []):
                        summary.append(f"| {suite}: note | | {note} |")
                    for change in result["changes"]:
                        if change["metric"].startswith("all/"):
                            summary.append(f"| {suite}: {change['metric']} | | delta {change.get('delta', 'unknown')} {change['unit']} |")
            else:
                failed = True
                status = "missing report; comparison unavailable"
        if suite == "multi-step":
            m5_path = args.output / "multi-step-m5.json"
            m5_path.unlink(missing_ok=True)
            m5_code = execute([str(args.cli), "assess-m5", "--report", str(path),
                               "--output", str(m5_path)], args.output / "multi-step-m5.log", 120)
            manifest["m5ExitCode"] = m5_code
            failed |= m5_code != 0
            if m5_path.is_file():
                assessment = read_json(m5_path)["assessment"]
                counts = assessment["counts"]
                summary.append(f"| M5 fixture evidence | {m5_code} | {assessment['verdict']}; grounded successes {counts['groundedSuccesses']}/{counts['attempts']}; real-tool target verified: false |")
            else:
                failed = True
                summary.append("| M5 | unavailable | Missing assessment; real-tool target unverified |")
        summary.append(f"| {suite} | {code} | {status} |")
        write_json(manifest_path, manifest)
    # Complete means all raw evidence exists, NOT that goals passed or model calls succeeded.
    manifest["reportErrors"] = report_errors(args.output, manifest["expectedTrials"], args.smoke)
    manifest["complete"] = not manifest["reportErrors"]
    failed |= not manifest["complete"]
    summary += ["", *manifest["reportErrors"]]
    manifest["jobFailed"] = failed
    write_json(manifest_path, manifest)
    summary += ["", "Raw reports, logs, reviews and provenance accompany this summary.",
                "No significance or causal claim is made. Bootstrap is not a drift pass.",
                "Only fixture tools execute; no personal calendar, reminders or notes are accessed."]
    (args.output / "summary.md").write_text("\n".join(summary) + "\n")
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--repo", required=True)
    prepare_parser.add_argument("--channel", choices=["stable", "beta"], required=True)
    prepare_parser.add_argument("--run-id", required=True)
    prepare_parser.add_argument("--output", type=Path, required=True)
    run_parser = commands.add_parser("run")
    run_parser.add_argument("--cli", type=Path, required=True)
    run_parser.add_argument("--output", type=Path, required=True)
    run_parser.add_argument("--baseline", type=Path)
    run_parser.add_argument("--smoke", action="store_true")
    run_parser.add_argument("--fail-on-regression", action="store_true")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args)
        return 0
    return batch(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Evaluation automation failed: {error}", file=sys.stderr)
        sys.exit(1)
