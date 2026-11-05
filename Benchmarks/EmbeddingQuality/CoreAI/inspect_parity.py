"""Recompute Core AI / pinned PyTorch parity from raw vectors before publishing quality metrics."""
import argparse
import json
import math
from pathlib import Path
import sys
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from score import evaluate, load_corpus, validate_vectors
from convert_minilm import MODEL, REVISION, TOLERANCE


def inspect(corpus, digest, report, reference, expected_run_id, ranking_limit=None):
    if report.get('schemaVersion') != 1 or report.get('corpusSHA256') != digest:
        raise ValueError('Probe report schema or corpus hash mismatch')
    if UUID(report['runID']) != UUID(expected_run_id):
        raise ValueError('Stale probe run')
    result = report.get('coreAI')
    if not result:
        raise ValueError('No opt-in Core AI result recorded')
    if result['status'] not in ('completed', 'failed', 'unavailable-os'):
        raise ValueError('Unknown Core AI status')
    if result['status'] != 'completed':
        if result.get('export') is not None:
            raise ValueError('Incomplete Core AI result cannot publish vectors')
        return {'schemaVersion': 1, 'status': result['status'], 'failure': result.get('failure'),
                'runID': report['runID'], 'corpusSHA256': digest, 'qualityScores': None}
    export = result['export']
    for candidate in [reference, export]:
        validate_vectors(candidate, corpus, digest)
        if candidate['metadata']['model'] != MODEL or candidate['metadata']['revision'] != REVISION:
            raise ValueError('Checkpoint provenance mismatch')
        if any(len(v) != 384 or abs(math.hypot(*v) - 1) > 1e-4 for v in candidate['vectors'].values()):
            raise ValueError('Expected normalized 384-dimensional MiniLM vectors')
    expected_count = len(corpus['documents']) + len(corpus['queries'])
    if result['comparedVectorCount'] != expected_count:
        raise ValueError('Incomplete parity coverage')
    maximum = max(abs(a - b) for key, vector in reference['vectors'].items()
                  for a, b in zip(vector, export['vectors'][key]))
    if maximum > TOLERANCE:
        raise ValueError('Raw vector parity exceeds the fixed absolute tolerance')
    return {'schemaVersion': 1, 'status': 'completed', 'runID': report['runID'], 'corpusSHA256': digest,
            'executionMetadata': report.get('metadata', {}), 'vectorCount': expected_count,
            'maximumAbsoluteError': maximum, 'absoluteTolerance': TOLERANCE,
            'qualityScores': {'pytorchReference': evaluate(corpus, digest, reference, ranking_limit=ranking_limit),
                              'coreAI': evaluate(corpus, digest, export, ranking_limit=ranking_limit)},
            'scope': 'Unquantized pinned MiniLM; not conversion/parity of the earlier 4-bit MLX artifact.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus')
    parser.add_argument('probe_report')
    parser.add_argument('reference')
    parser.add_argument('output')
    parser.add_argument('--expected-run-id', required=True)
    parser.add_argument('--ranking-limit', type=int)
    args = parser.parse_args()
    corpus, digest = load_corpus(args.corpus)
    result = inspect(corpus, digest, json.loads(Path(args.probe_report).read_text()),
                     json.loads(Path(args.reference).read_text()), args.expected_run_id, args.ranking_limit)
    Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + '\n')
    if result['status'] != 'completed':
        raise SystemExit(2)


if __name__ == '__main__':
    main()
