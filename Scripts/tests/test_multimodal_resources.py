import copy
import hashlib
import importlib.util
import json
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("multimodal_resources", ROOT / "Benchmarks/MultimodalResources/inspect.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
WORKLOAD = (ROOT / "Benchmarks/MultimodalResources/workload.json").read_bytes()
RUN_ID = str(uuid.uuid4()).upper()


def records(seconds=300):
    rows = []
    def add(kind, elapsed, **fields):
        rows.append(dict(schemaVersion=1, runID=RUN_ID, sequence=len(rows), kind=kind, elapsedSeconds=elapsed, **fields))
    snap = dict(thermal="nominal", batteryLevel=.8, batteryState="unplugged", foreground=True,
                lowPowerMode=False, brightness=.7, footprintBytes=1048576)
    add("started", 0, metadata=dict(workloadSHA256=hashlib.sha256(WORKLOAD).hexdigest(),
        secondsPerPhase=str(seconds), intervalMilliseconds="250"))
    for index, path in enumerate(MODULE.PATHS):
        start = index * seconds
        add("phaseStarted", start, path=path, snapshot=copy.deepcopy(snap))
        add("sample", start + .1, path=path, snapshot=copy.deepcopy(snap), iteration=1, latencySeconds=.01)
        end = copy.deepcopy(snap)
        end["batteryLevel"] = .79
        add("phaseEnded", start + seconds, path=path, snapshot=end, iteration=1)
    add("finished", len(MODULE.PATHS) * seconds)
    return rows


class MultimodalResourceInspectorTests(unittest.TestCase):
    def test_complete_observed_discharge_is_reported_without_rate_extrapolation(self):
        report = MODULE.inspect(WORKLOAD, records(), RUN_ID)
        for path in report["paths"].values():
            self.assertTrue(path["batteryEligible"])
            self.assertAlmostEqual(path["batteryPercentagePoints"], 1)
            self.assertEqual(path["maxSampledFootprintMiB"], 1)
            self.assertNotIn("drainPerHour", path)

    def test_wired_short_run_is_never_battery_evidence(self):
        rows = records(60)
        for row in rows:
            if "snapshot" in row:
                row["snapshot"]["batteryState"] = "charging"
        report = MODULE.inspect(WORKLOAD, rows, RUN_ID)
        self.assertTrue(all(not p["batteryEligible"] and p["batteryPercentagePoints"] is None for p in report["paths"].values()))

    def test_any_condition_change_invalidates_battery(self):
        for key, value in [("batteryState", "full"), ("batteryLevel", .9), ("brightness", .9), ("lowPowerMode", True), ("brightness", None)]:
            with self.subTest(key=key, value=value):
                rows = records()
                rows[2]["snapshot"][key] = value
                report = MODULE.inspect(WORKLOAD, rows, RUN_ID)
                self.assertFalse(report["paths"]["idle"]["batteryEligible"])

    def test_rejects_stale_id_and_wrong_fixture(self):
        with self.assertRaises(ValueError):
            MODULE.inspect(WORKLOAD, records(), str(uuid.uuid4()))
        with self.assertRaises(ValueError):
            MODULE.inspect(WORKLOAD + b" ", records(), RUN_ID)

    def test_partial_logs_require_explicit_opt_in_and_never_claim_battery(self):
        rows = records()[:3]
        with self.assertRaises(ValueError):
            MODULE.inspect(WORKLOAD, rows, RUN_ID)
        report = MODULE.inspect(WORKLOAD, rows, RUN_ID, allow_incomplete=True)
        self.assertFalse(report["paths"]["idle"]["batteryEligible"])

    def test_rejects_sequence_time_and_missing_phase_corruption(self):
        variants = []
        row = records(); row[2]["sequence"] = 99; variants.append(row)
        row = records(); row[2]["elapsedSeconds"] = float("nan"); variants.append(row)
        row = records(); row[3]["elapsedSeconds"] = -.1; variants.append(row)
        row = records(); row[-1]["kind"] = "unknown"; variants.append(row)
        row = records(); row[3]["iteration"] = 9; variants.append(row)
        row = records(); row[1]["path"] = "synthesis"; variants.append(row)
        for row in variants:
            with self.assertRaises(ValueError):
                MODULE.inspect(WORKLOAD, row, RUN_ID)

    def test_unknown_samples_and_records_after_terminal_are_rejected(self):
        row = records(); row[1]["snapshot"]["batteryLevel"] = 42
        with self.assertRaises(ValueError):
            MODULE.inspect(WORKLOAD, row, RUN_ID)
        row = records(); row.append(copy.deepcopy(row[-1]))
        with self.assertRaises(ValueError):
            MODULE.inspect(WORKLOAD, row, RUN_ID)

    def test_failed_and_unavailable_paths_are_not_zero_cost_measurements(self):
        rows = records()
        rows[7:10] = [dict(schemaVersion=1, runID=RUN_ID, kind="unavailable", path="transcription", detail="missing assets", elapsedSeconds=600)]
        for i, row in enumerate(rows):
            row["sequence"] = i
        path = MODULE.inspect(WORKLOAD, rows, RUN_ID)["paths"]["transcription"]
        self.assertEqual(path["status"], "unavailable")
        self.assertIsNone(path["latencyP50Milliseconds"])
        self.assertFalse(path["batteryEligible"])
        failed = records()
        failed[2]["kind"] = "failed"
        failed[2]["detail"] = "fixture failed"
        failed[3]["iteration"] = 0
        path = MODULE.inspect(WORKLOAD, failed, RUN_ID)["paths"]["idle"]
        self.assertEqual(path["status"], "failed")
        self.assertFalse(path["batteryEligible"])


if __name__ == "__main__":
    unittest.main()
