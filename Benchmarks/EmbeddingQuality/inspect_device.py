"""Validate an isolated app report, score completed paths, and compare actual SDK vectors."""
import argparse
import json
import math
from pathlib import Path
from uuid import UUID

from score import evaluate, load_corpus

PATHS = {'natural-language-sentence', 'natural-language-word-average', 'sdk-default'}


def inspect(corpus, digest, report, expected_run_id=None):
    if report.get('schemaVersion') != 1 or report.get('corpusSHA256') != digest:
        raise ValueError('Device report schema or corpus hash mismatch')
    run_id = UUID(report['runID'])
    if expected_run_id is not None and run_id != UUID(expected_run_id):
        raise ValueError('Stale device report: run ID mismatch')
    results = report['results']
    if len(results) != len(PATHS) or {r['path'] for r in results} != PATHS:
        raise ValueError('Expected exactly one result for each requested path')
    scores, exports = {}, {}
    for result in results:
        status = result['status']
        if status == 'completed':
            export = result.get('export')
            if export is None or export['provider'] != result['path']:
                raise ValueError('Completed result lacks its own export')
            scores[result['path']] = evaluate(corpus, digest, export)
            exports[result['path']] = export
        elif status not in ('unavailable', 'failed') or result.get('export') is not None:
            raise ValueError('Invalid status or partial export on incomplete path')
    matches = []
    sdk = exports.get('sdk-default', {}).get('vectors')
    if sdk:
        for name in sorted(PATHS - {'sdk-default'}):
            candidate = exports.get(name, {}).get('vectors')
            if candidate and all(len(sdk[i]) == len(candidate[i]) and all(
                    math.isclose(a, b, rel_tol=0, abs_tol=1e-6)
                    for a, b in zip(sdk[i], candidate[i])) for i in sdk):
                matches.append(name)
    return {'schemaVersion': 1, 'runID': str(run_id), 'corpusSHA256': digest,
            'metadata': report.get('metadata', {}),
            'statuses': {r['path']: r['status'] for r in results},
            'sdkVectorMatches': matches,
            'matchRule': 'Every raw component within absolute 1e-6; matching this fixture is not proof of all future behavior.',
            'scores': scores}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus')
    parser.add_argument('device_report')
    parser.add_argument('output')
    parser.add_argument('--expected-run-id')
    args = parser.parse_args()
    corpus, digest = load_corpus(args.corpus)
    result = inspect(corpus, digest, json.loads(Path(args.device_report).read_text()), args.expected_run_id)
    Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + '\n')


if __name__ == '__main__':
    main()
