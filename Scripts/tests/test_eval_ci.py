"""Offline tests for evaluation orchestration; subprocesses are simulated."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("eval_ci", Path(__file__).parents[1] / "eval_ci.py")
eval_ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eval_ci)


def fake_m5(command, verdict="synthetic"):
    if command[1] != "assess-m5":
        return False
    path = Path(command[command.index("--output") + 1])
    eval_ci.write_json(path, {"assessment": {"verdict": verdict,
        "counts": {"groundedSuccesses": 0, "attempts": 0}}})
    return True


class EvaluationAutomationTests(unittest.TestCase):
    def test_scheduled_skip_requires_same_build_source_and_xcode(self):
        current = {"osBuild": "27A1", "sourceRevision": "a", "xcode": "Xcode 27"}
        self.assertFalse(eval_ci.should_run("schedule", current, current))
        self.assertTrue(eval_ci.should_run("schedule", current, dict(current, jobFailed=True)))
        for field in current:
            previous = dict(current, **{field: "old"})
            self.assertTrue(eval_ci.should_run("schedule", current, previous))
        self.assertTrue(eval_ci.should_run("schedule", current, None))
        for event in ["release", "workflow_dispatch", "repository_dispatch"]:
            self.assertTrue(eval_ci.should_run(event, current, current))

    def test_artifact_candidates_are_channel_scoped_expiry_aware_and_newest_first(self):
        def artifact(run, channel="beta", expired=False):
            return {"name": "localagentkit-eval-" + channel, "expired": expired,
                    "workflow_run": {"id": run}, "created_at": f"2026-10-{run:02d}"}
        pages = [{"artifacts": [artifact(1), artifact(4), artifact(3, expired=True)]},
                 {"artifacts": [artifact(5, "stable"), artifact(6), artifact(2)]}]
        actual = eval_ci.baseline_candidates(pages, "beta", "6")
        self.assertEqual([a["workflow_run"]["id"] for a in actual], [4, 2, 1])

    def test_baseline_ignores_foreign_and_pr_workflows_and_incomplete_evidence(self):
        def artifact(run):
            return {"name": "localagentkit-eval-beta", "expired": False,
                    "workflow_run": {"id": run}, "created_at": str(run)}
        pages = [{"artifacts": [artifact(i) for i in range(1, 5)]}]
        def run_metadata(endpoint):
            run = int(endpoint.rsplit("/", 1)[1])
            return {"status": "completed", "path": "other.yml" if run == 4 else eval_ci.WORKFLOW,
                    "head_repository": {"full_name": "owner/repo"},
                    "event": "pull_request" if run == 3 else "release"}
        def download(command, **kwargs):
            target = Path(command[command.index("--dir") + 1])
            run = command[3]
            eval_ci.write_json(target / "manifest.json", {
                "complete": run == "1", "synthetic": False, "channel": "beta",
                "expectedTrials": {suite: 1 for suite in eval_ci.SUITES}})
            for suite in eval_ci.SUITES:
                eval_ci.write_json(target / f"{suite}.json", {"synthetic": False, "results": [
                    {"goalID": "goal", "repetition": 1, "profileID": "light", "toolMode": "registered", "probeID": "probe"}]})
        with tempfile.TemporaryDirectory() as directory, patch.object(eval_ci, "command_output", return_value=json.dumps(pages)), patch.object(eval_ci, "gh_json", side_effect=run_metadata), patch.object(eval_ci.subprocess, "run", side_effect=download) as process:
            target, manifest = eval_ci.find_baseline("owner/repo", "beta", "9", Path(directory))
            self.assertEqual(target.name, "1")
            self.assertTrue(manifest["complete"])
            self.assertEqual(process.call_count, 2)

    def test_api_failure_is_not_silently_treated_as_bootstrap(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(eval_ci, "command_output", side_effect=subprocess.CalledProcessError(1, "gh")):
            with self.assertRaises(subprocess.CalledProcessError):
                eval_ci.find_baseline("owner/repo", "beta", "9", Path(directory))

    def test_expected_build_is_verified_before_measurement(self):
        with patch.object(eval_ci.platform, "system", return_value="Darwin"), patch.object(eval_ci.platform, "machine", return_value="arm64"), patch.object(eval_ci, "command_output", return_value="27A1"), patch.dict(eval_ci.os.environ, {"EXPECTED_OS_BUILD": "27A2"}):
            with self.assertRaisesRegex(ValueError, "Expected OS build"):
                eval_ci.provenance("beta")

    def test_all_suites_continue_after_failure_and_preserve_exit_codes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            eval_ci.write_json(root / "manifest.json", {"channel": "beta", "osBuild": "27A1", "sourceRevision": "abc"})
            args = argparse.Namespace(cli=Path("/fake/cli"), output=root, baseline=None,
                                      smoke=False, fail_on_regression=False)
            def execute(command, log, timeout):
                if fake_m5(command):
                    return 0
                suite = command[command.index("--suite") + 1]
                path = Path(command[command.index("--output") + 1])
                count = eval_ci.expected_trials(suite, False)
                eval_ci.write_json(path, {"suite": suite, "synthetic": False, "results": [
                    {"goalID": str(i), "repetition": 1, "profileID": "light", "toolMode": "registered", "probeID": str(i)} for i in range(count)]})
                return 3 if suite == "refusal" else 0
            with patch.object(eval_ci, "execute", side_effect=execute) as runner:
                self.assertEqual(eval_ci.batch(args), 1)
                self.assertEqual(runner.call_count, 5)
            manifest = eval_ci.read_json(root / "manifest.json")
            self.assertTrue(manifest["complete"])
            self.assertFalse(manifest["synthetic"])
            self.assertEqual(manifest["suiteExitCodes"]["refusal"], 3)
            self.assertIn("no-baseline", (root / "summary.md").read_text())

    def test_missing_report_remains_incomplete_and_comparison_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = argparse.Namespace(cli=Path("/fake/cli"), output=root / "out", baseline=root / "old",
                                      smoke=True, fail_on_regression=True)
            args.baseline.mkdir()
            with patch.object(eval_ci, "execute", return_value=124):
                self.assertEqual(eval_ci.batch(args), 1)
            manifest = eval_ci.read_json(args.output / "manifest.json")
            self.assertFalse(manifest["complete"])
            self.assertTrue(manifest["synthetic"])
            self.assertEqual(len(manifest["suiteExitCodes"]), 4)
            self.assertIn("comparison unavailable", (args.output / "summary.md").read_text())

    def test_prepare_skip_outputs_and_baselines_are_outside_uploaded_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = {"osBuild": "27A1", "sourceRevision": "a", "xcode": "27"}
            args = argparse.Namespace(output=root / "reports", repo="owner/repo", channel="beta", run_id="2")
            with patch.object(eval_ci, "provenance", return_value=current), patch.object(eval_ci, "find_baseline", return_value=(root / "prior", dict(current, runID="1"))) as find, patch.dict(eval_ci.os.environ, {"GITHUB_EVENT_NAME": "schedule", "GITHUB_OUTPUT": str(root / "outputs"), "GITHUB_STEP_SUMMARY": str(root / "summary")}):
                eval_ci.prepare(args)
            self.assertIn("should_run=false", (root / "outputs").read_text())
            self.assertTrue(eval_ci.read_json(args.output / "manifest.json")["skippedUnchanged"])
            self.assertEqual(find.call_args.args[-1], root / "reports-baselines")

    def test_zero_exit_without_evidence_still_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(cli=Path("/fake/cli"), output=Path(directory), baseline=None,
                                      smoke=True, fail_on_regression=False)
            with patch.object(eval_ci, "execute", return_value=0):
                self.assertEqual(eval_ci.batch(args), 1)
            manifest = eval_ci.read_json(args.output / "manifest.json")
            self.assertFalse(manifest["complete"])
            self.assertEqual(len(manifest["reportErrors"]), 4)

    def test_provisional_comparison_fails_job_but_retains_all_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = argparse.Namespace(cli=Path("/fake/cli"), output=root / "out", baseline=root / "old",
                                      smoke=True, fail_on_regression=False)
            args.baseline.mkdir()
            for suite in eval_ci.SUITES:
                (args.baseline / f"{suite}.json").write_text("{}")
            def execute(command, log, timeout):
                if fake_m5(command):
                    return 0
                path = Path(command[command.index("--output") + 1])
                if command[1] == "compare":
                    eval_ci.write_json(path, {"status": "provisional", "observedRegression": False,
                                             "changes": [], "warnings": ["missing metadata"]})
                    return 3
                suite = command[command.index("--suite") + 1]
                count = eval_ci.expected_trials(suite, True)
                eval_ci.write_json(path, {"synthetic": True, "results": [
                    {"goalID": str(i), "repetition": 1, "profileID": "light", "toolMode": "registered", "probeID": str(i)} for i in range(count)]})
                return 0
            with patch.object(eval_ci, "execute", side_effect=execute):
                self.assertEqual(eval_ci.batch(args), 1)
            manifest = eval_ci.read_json(args.output / "manifest.json")
            self.assertTrue(manifest["complete"])
            self.assertEqual(set(manifest["comparisonExitCodes"].values()), {3})
            self.assertIn("missing metadata", (args.output / "summary.md").read_text())

    def test_stale_output_cannot_be_promoted_after_failed_rerun(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for suite in eval_ci.SUITES:
                (root / f"{suite}.json").write_text("old report")
                (root / f"{suite}-comparison.json").write_text("old comparison")
            args = argparse.Namespace(cli=Path("/fake/cli"), output=root, baseline=None,
                                      smoke=True, fail_on_regression=False)
            with patch.object(eval_ci, "execute", return_value=1):
                self.assertEqual(eval_ci.batch(args), 1)
            self.assertFalse(eval_ci.read_json(root / "manifest.json")["complete"])
            self.assertFalse((root / "context-load.json").exists())
            args.baseline = root
            with self.assertRaisesRegex(ValueError, "differ"):
                eval_ci.batch(args)

    def test_m5_failure_is_retained_and_fails_an_otherwise_successful_batch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = argparse.Namespace(cli=Path("/fake/cli"), output=root, baseline=None,
                                      smoke=True, fail_on_regression=False)
            def execute(command, log, timeout):
                if fake_m5(command, "belowTarget"):
                    return 2
                suite = command[command.index("--suite") + 1]
                count = eval_ci.expected_trials(suite, True)
                eval_ci.write_json(Path(command[command.index("--output") + 1]), {
                    "synthetic": True, "results": [
                        {"goalID": str(i), "repetition": 1, "profileID": "light", "toolMode": "registered", "probeID": str(i)} for i in range(count)]})
                return 0
            with patch.object(eval_ci, "execute", side_effect=execute):
                self.assertEqual(eval_ci.batch(args), 1)
            manifest = eval_ci.read_json(root / "manifest.json")
            self.assertTrue(manifest["complete"])
            self.assertEqual(manifest["m5ExitCode"], 2)
            self.assertIn("belowTarget", (root / "summary.md").read_text())

    def test_process_timeout_is_recorded(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(eval_ci.subprocess, "run", side_effect=subprocess.TimeoutExpired("cli", 1)):
            log = Path(directory) / "run.log"
            self.assertEqual(eval_ci.execute(["cli"], log, 1), 124)
            self.assertIn("incomplete", log.read_text())


if __name__ == "__main__":
    unittest.main()
