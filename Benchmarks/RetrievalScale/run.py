"""Run isolated macOS release benchmark processes; preserve all samples, errors and provenance."""
import argparse
import hashlib
import json
import math
import platform
import random
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def percentile(samples, fraction):
    if not samples or any(not math.isfinite(x) or x < 0 for x in samples):
        raise ValueError('Expected nonnegative finite samples')
    return sorted(samples)[max(0, math.ceil(fraction * len(samples)) - 1)]


def memory_metrics(stderr):
    values = {}
    for label, key in [('maximum resident set size', 'maximumResidentBytes'),
                       ('peak memory footprint', 'peakFootprintBytes')]:
        found = re.findall(r'^\s*(\d+)\s+' + label + r'\s*$', stderr, re.MULTILINE)
        if len(found) != 1 or int(found[0]) <= 0:
            raise ValueError('Missing/invalid macOS time metric: ' + label)
        values[key] = int(found[0])
    return values


def validate_report(report, workload, case, operation):
    if (report.get('schemaVersion') != 1 or report.get('store') != case['store'] or
            report.get('count') != case['count'] or report.get('dimensions') != case['dimensions'] or
            report.get('operation') != operation):
        raise ValueError('Benchmark output does not match requested case')
    samples = report['searchMilliseconds']
    expected = workload['queries'] if operation == 'query' else 0
    if len(samples) != expected:
        raise ValueError('Missing query samples')
    if samples:
        percentile(samples, 0.95)
    expected_hits = ((workload['warmups'] + workload['queries']) *
                     min(case['count'], workload['candidateLimit'])) if operation == 'query' else 0
    if report['resultCount'] != expected_hits:
        raise ValueError('Unexpected number of returned passages')
    for key in ['initializationMilliseconds', 'loadMilliseconds']:
        value = report.get(key)
        if value is not None and (not math.isfinite(value) or value < 0):
            raise ValueError('Invalid timing')
    if operation == 'query' and case['store'] == 'file' and report.get('loadMilliseconds') is None:
        raise ValueError('Missing fresh-instance load timing')
    return report


def measure(binary, workload, case, path, operation):
    command = ['/usr/bin/time', '-l', str(binary), operation, case['store'], str(case['count']),
               str(case['dimensions']), str(path), str(workload['queries']), str(workload['warmups']),
               str(workload['candidateLimit']), str(workload['textCharacters']), str(workload['seed']),
               str(workload['fileMaximumBytes'])]
    run = subprocess.run(command, capture_output=True, text=True)
    if run.returncode:
        raise RuntimeError('Benchmark failed: ' + run.stderr[-2000:])
    report = validate_report(json.loads(run.stdout), workload, case, operation)
    return {**report, **memory_metrics(run.stderr)}


def summarize(runs, workload):
    groups = {}
    for run in runs:
        key = (run['store'], run['count'], run['dimensions'])
        groups.setdefault(key, []).append(run)
    expected = {(store, count, dimensions) for store in workload['stores']
                for count in workload['counts'] for dimensions in workload['dimensions']}
    if set(groups) != expected:
        raise ValueError('Missing or unexpected benchmark cases')
    output = []
    target = workload['hostAssessment']
    for (store, count, dimensions), rows in sorted(groups.items()):
        if (len(rows) != workload['repetitions'] or
                {r['repetition'] for r in rows} != set(range(workload['repetitions']))):
            raise ValueError('Missing repetitions')
        pooled = [x for row in rows for x in row['searchMilliseconds']]
        row = {'store': store, 'count': count, 'dimensions': dimensions,
               'samples': len(pooled), 'queryP50Milliseconds': percentile(pooled, .5),
               'queryP95Milliseconds': percentile(pooled, .95),
               'queryMaximumMilliseconds': max(pooled),
               'maximumResidentBytes': max(r['maximumResidentBytes'] for r in rows),
               'peakFootprintBytes': max(r['peakFootprintBytes'] for r in rows),
               'snapshotBytes': max(r['snapshotBytes'] for r in rows),
               'fitsDefaultFileBudget': all(r['fitsDefaultFileBudget'] for r in rows),
               'queryBudgetExceededRepeats': sum(percentile(r['searchMilliseconds'], .95) >
                                                 target['warmQueryP95Milliseconds'] for r in rows)}
        loads = [r['loadMilliseconds'] for r in rows if r.get('loadMilliseconds') is not None]
        row['maximumLoadMilliseconds'] = max(loads) if loads else None
        row['assessmentApplies'] = count == target['count']
        row['annInvestigationWarranted'] = row['assessmentApplies'] and row['queryBudgetExceededRepeats'] >= 2
        output.append(row)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    workload_raw = (HERE / 'workload.json').read_bytes()
    workload = json.loads(workload_raw)
    cases = [{'store': store, 'count': count, 'dimensions': dimensions}
             for store in workload['stores'] for count in workload['counts'] for dimensions in workload['dimensions']]
    runs, preparations = [], []
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError('Refusing to overwrite existing measurements')
    metadata = {'schemaVersion': 1, 'workload': workload,
                'workloadSHA256': hashlib.sha256(workload_raw).hexdigest(),
                'harnessSHA256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in [Path(__file__).resolve(), HERE / 'Package.swift',
                                            HERE / 'Sources/RetrievalScale/main.swift',
                                            ROOT / 'Sources/LocalAgentKitProviders/FileVectorStore/FileVectorStore.swift',
                                            ROOT / 'Sources/LocalAgentKitProviders/InMemoryVectorStore/InMemoryVectorStore.swift']},
                'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                'host': {'os': subprocess.check_output(['sw_vers'], text=True).strip(),
                         'architecture': platform.machine(), 'python': platform.python_version(),
                         'cpu': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
                         'physicalMemoryBytes': int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)),
                         'swift': subprocess.check_output(['xcrun', 'swift', '--version'], text=True).strip()},
                'sdkCommit': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
                'memoryMeasurement': 'macOS /usr/bin/time -l whole-process high-water bytes; not live heap or index-only allocation'}
    (args.output / 'manifest.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
    def measured(case, path, operation):
        try:
            return measure(binary, workload, case, path, operation)
        except Exception as error:
            (args.output / 'failure.json').write_text(json.dumps(
                {'case': case, 'operation': operation, 'error': str(error)}, indent=2) + '\n')
            raise
    with tempfile.TemporaryDirectory(prefix='lak-scale-') as temporary:
        for case in cases:
            if case['store'] == 'file':
                path = Path(temporary) / f"{case['count']}-{case['dimensions']}.json"
                preparations.append(measured(case, path, 'prepare'))
                (args.output / 'runs.json').write_text(json.dumps({'preparations': preparations, 'runs': runs}, indent=2, sort_keys=True) + '\n')
        for repetition in range(workload['repetitions']):
            ordered = list(cases)
            random.Random(workload['seed'] + repetition).shuffle(ordered)
            for case in ordered:
                path = Path(temporary) / f"{case['count']}-{case['dimensions']}.json"
                run = measured(case, path, 'query')
                runs.append({**run, 'repetition': repetition})
                print(case, 'repeat', repetition, flush=True)
                (args.output / 'runs.json').write_text(json.dumps({'preparations': preparations, 'runs': runs}, indent=2, sort_keys=True) + '\n')
    summary = summarize(runs, workload)
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
