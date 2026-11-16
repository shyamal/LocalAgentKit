#!/usr/bin/env python3
"""Validate a fresh probe log and summarize observations, without energy attribution."""
import argparse
import hashlib
import json
import math
import statistics
import uuid
from pathlib import Path

PATHS = ["idle", "ocr", "transcription", "synthesis"]


def number(value, minimum=0, maximum=math.inf):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not minimum <= value <= maximum:
        raise ValueError("Invalid numeric observation")
    return value


def snapshot(value):
    if not isinstance(value, dict):
        raise ValueError("Missing snapshot")
    if value.get("thermal") not in {"nominal", "fair", "serious", "critical", "unknown"}:
        raise ValueError("Unknown thermal value")
    if value.get("batteryState") not in {"unknown", "unplugged", "charging", "full"}:
        raise ValueError("Unknown battery state")
    for key in ("foreground", "lowPowerMode"):
        if type(value.get(key)) is not bool:
            raise ValueError("Invalid snapshot flags")
    for key in ("batteryLevel", "brightness"):
        if value.get(key) is not None:
            number(value[key], 0, 1)
    if value.get("footprintBytes") is not None:
        if type(value["footprintBytes"]) is not int:
            raise ValueError("Invalid footprint")
        number(value["footprintBytes"])
    return value


def inspect(workload_bytes, records, expected_run_id, allow_incomplete=False):
    expected = str(uuid.UUID(expected_run_id)).upper()
    workload = json.loads(workload_bytes)
    if workload.get("version") != 1 or workload.get("pathOrder") != PATHS:
        raise ValueError("Unsupported workload")
    if not records or records[0].get("kind") != "started":
        raise ValueError("Missing run header")
    metadata = records[0].get("metadata", {})
    if metadata.get("workloadSHA256") != hashlib.sha256(workload_bytes).hexdigest():
        raise ValueError("Wrong workload hash")
    seconds = int(metadata["secondsPerPhase"])
    interval = int(metadata["intervalMilliseconds"])
    if not 1 <= seconds <= 300 or not 250 <= interval <= 5000:
        raise ValueError("Invalid measurement plan")
    if interval != workload["intervalMilliseconds"]:
        raise ValueError("Pacing differs from pinned workload")
    previous = -1.0
    index = 0
    current = None
    terminal = None
    phases = {}
    for sequence, record in enumerate(records):
        if terminal is not None:
            raise ValueError("Records after terminal event")
        if type(record.get("schemaVersion")) is not int or type(record.get("sequence")) is not int or record.get("schemaVersion") != 1 or record.get("runID") != expected or record.get("sequence") != sequence:
            raise ValueError("Stale run, unsupported schema or broken sequence")
        elapsed = number(record.get("elapsedSeconds"))
        if elapsed < previous:
            raise ValueError("Clock moved backwards")
        previous = elapsed
        kind = record.get("kind")
        path = record.get("path")
        if kind == "started":
            if sequence != 0 or path is not None:
                raise ValueError("Duplicate header")
            continue
        if kind in {"finished", "cancelled", "interrupted"}:
            if path is not None:
                raise ValueError("Terminal event has a path")
            if kind == "finished" and (index != len(PATHS) or current is not None):
                raise ValueError("Run finished with missing phases")
            terminal = kind
            continue
        if kind in {"phaseStarted", "unavailable"}:
            if current is not None or index >= len(PATHS) or path != PATHS[index]:
                raise ValueError("Wrong phase order")
            phases[path] = {"status": "unavailable" if kind == "unavailable" else "incomplete", "samples": [], "latencies": [], "calls": 0}
            if kind == "unavailable":
                if not record.get("detail"):
                    raise ValueError("Missing unavailability reason")
                phases[path]["reason"] = record["detail"]
                index += 1
            else:
                current = path
                phases[path]["start"] = elapsed
                phases[path]["samples"].append(snapshot(record.get("snapshot")))
            continue
        if current is None or path != current:
            raise ValueError("Event outside active phase")
        phase = phases[current]
        if kind == "sample":
            if phase["status"] == "failed" or type(record.get("iteration")) is not int or record.get("iteration") != phase["calls"] + 1:
                raise ValueError("Invalid iteration or result after failure")
            phase["calls"] += 1
            phase["latencies"].append(number(record.get("latencySeconds")))
            phase["samples"].append(snapshot(record.get("snapshot")))
        elif kind == "failed":
            if phase["status"] == "failed" or not record.get("detail"):
                raise ValueError("Invalid failure")
            phase["status"] = "failed"
            phase["reason"] = record["detail"]
        elif kind == "phaseEnded":
            if record.get("iteration") != phase["calls"]:
                raise ValueError("Wrong final iteration")
            phase["samples"].append(snapshot(record.get("snapshot")))
            phase["durationSeconds"] = elapsed - phase["start"]
            if phase["status"] != "failed":
                if phase["durationSeconds"] < seconds or phase["calls"] == 0:
                    raise ValueError("Incomplete phase declared completed")
                if any(not s["foreground"] or s["thermal"] == "critical" for s in phase["samples"]):
                    raise ValueError("Completed phase ignored a stop condition")
                phase["status"] = "completed"
            current = None
            index += 1
        else:
            raise ValueError("Unknown event")
    if terminal != "finished" and not allow_incomplete:
        raise ValueError("Incomplete or interrupted run")
    results = {}
    for path, phase in phases.items():
        samples = phase.pop("samples")
        latencies = phase.pop("latencies")
        phase.pop("start", None)
        reasons = []
        duration = phase.get("durationSeconds", 0)
        if phase["status"] != "completed" or terminal != "finished":
            reasons.append("phase-or-run-incomplete")
        if duration < workload["batterySecondsPerPhase"]:
            reasons.append("shorter-than-battery-protocol")
        if not samples or any(s["batteryState"] != "unplugged" or s.get("batteryLevel") is None for s in samples):
            reasons.append("not-continuously-observed-on-battery")
        if samples and (any(not s["foreground"] for s in samples) or len({s["lowPowerMode"] for s in samples}) != 1):
            reasons.append("foreground-or-power-mode-changed")
        if samples and (any(s.get("brightness") is None for s in samples) or max(s["brightness"] for s in samples) - min(s["brightness"] for s in samples) > 0.01):
            reasons.append("brightness-unknown-or-changed")
        if samples and any(s["thermal"] in {"critical", "unknown"} for s in samples):
            reasons.append("thermal-state-unknown-or-critical")
        levels = [s.get("batteryLevel") for s in samples]
        if levels and all(v is not None for v in levels) and any(b > a + 1e-6 for a, b in zip(levels, levels[1:])):
            reasons.append("battery-level-increased")
        phase["batteryEligible"] = not reasons
        phase["batteryExclusions"] = reasons
        phase["batteryPercentagePoints"] = (levels[0] - levels[-1]) * 100 if not reasons else None
        phase["thermalCounts"] = {state: sum(s["thermal"] == state for s in samples) for state in sorted({s["thermal"] for s in samples})}
        footprints = [s["footprintBytes"] for s in samples if s.get("footprintBytes") is not None]
        phase["maxSampledFootprintMiB"] = max(footprints) / 1048576 if footprints else None
        phase["latencyP50Milliseconds"] = statistics.median(latencies) * 1000 if latencies else None
        phase["latencyP95Milliseconds"] = sorted(latencies)[math.ceil(len(latencies) * .95) - 1] * 1000 if latencies else None
        results[path] = phase
    return {"schemaVersion": 1, "runID": expected, "terminal": terminal,
            "metadata": metadata, "paths": results,
            "limits": "Observed battery percentage only, not energy attribution. Fixed phase order and warmed caches; sampled footprint is not process peak. No baseline subtraction or per-hour extrapolation."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workload", type=Path)
    parser.add_argument("log", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--expected-run-id", required=True)
    parser.add_argument("--allow-incomplete", action="store_true")
    args = parser.parse_args()
    records = [json.loads(line) for line in args.log.read_text().splitlines()]
    result = inspect(args.workload.read_bytes(), records, args.expected_run_id, args.allow_incomplete)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
