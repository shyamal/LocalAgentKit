import copy
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Benchmarks/EmbeddingQuality/CoreAI'))
import inspect_parity


class CoreAIParityTests(unittest.TestCase):
    def setUp(self):
        self.corpus = {'schemaVersion': 1, 'documents': [{'id': 'd', 'text': 'Document'}],
                       'queries': [{'id': 'q', 'text': 'Question', 'relevant': ['d']}]}
        self.run = '5F6426D0-4D01-4BBE-B692-2A71586C5D03'
        self.reference = {'schemaVersion': 1, 'corpusSHA256': 'hash', 'provider': 'pytorch',
                          'metadata': {'model': inspect_parity.MODEL, 'revision': inspect_parity.REVISION},
                          'vectors': {'d': [1.] + [0.] * 383, 'q': [1.] + [0.] * 383}}
        self.report = {'schemaVersion': 1, 'corpusSHA256': 'hash', 'runID': self.run,
                       'coreAI': {'status': 'completed', 'comparedVectorCount': 2,
                                  'maximumAbsoluteError': 0, 'export': copy.deepcopy(self.reference)}}

    def inspect(self):
        return inspect_parity.inspect(self.corpus, 'hash', self.report, self.reference, self.run)

    def test_raw_parity_is_recomputed_before_quality_scores(self):
        result = self.inspect()
        self.assertEqual(result['maximumAbsoluteError'], 0)
        self.assertEqual(result['vectorCount'], 2)
        self.assertEqual(result['qualityScores']['coreAI']['metrics']['recallAtK'], 1)

    def test_reported_zero_error_cannot_hide_wrong_raw_vectors(self):
        vector = self.report['coreAI']['export']['vectors']['q']
        vector[:2] = [math.sqrt(1 - 0.02 ** 2), 0.02]
        with self.assertRaisesRegex(ValueError, 'parity'):
            self.inspect()

    def test_stale_runs_checkpoint_changes_missing_ids_and_partial_coverage_fail(self):
        changes = [lambda r: r.update(runID='00000000-0000-4000-8000-000000000001'),
                   lambda r: r['coreAI'].update(comparedVectorCount=1),
                   lambda r: r['coreAI']['export']['metadata'].update(revision='other'),
                   lambda r: r['coreAI']['export']['vectors'].pop('q')]
        original = copy.deepcopy(self.report)
        for change in changes:
            self.report = copy.deepcopy(original)
            change(self.report)
            with self.assertRaises(ValueError):
                self.inspect()

    def test_invalid_dimensions_nonfinite_or_unnormalized_vectors_fail(self):
        for vector in [[1], [math.nan] * 384, [2.] + [0.] * 383]:
            self.report['coreAI']['export']['vectors']['q'] = vector
            with self.assertRaises(ValueError):
                self.inspect()

    def test_failed_or_unavailable_runs_have_no_quality_claim_and_no_partial_export(self):
        self.report['coreAI'] = {'status': 'failed', 'failure': 'Synthetic failure'}
        result = self.inspect()
        self.assertIsNone(result['qualityScores'])
        self.report['coreAI']['export'] = self.reference
        with self.assertRaises(ValueError):
            self.inspect()
        self.report['coreAI'] = {'status': 'unknown'}
        with self.assertRaises(ValueError):
            self.inspect()

    def test_cli_saves_failure_evidence_but_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus = root / 'corpus.json'
            corpus.write_text(json.dumps(self.corpus))
            report = copy.deepcopy(self.report)
            report['corpusSHA256'] = hashlib.sha256(corpus.read_bytes()).hexdigest()
            report['coreAI'] = {'status': 'failed', 'failure': 'Synthetic failure'}
            (root / 'report.json').write_text(json.dumps(report))
            (root / 'reference.json').write_text('{}')
            output = root / 'output.json'
            result = subprocess.run([sys.executable, str(ROOT / 'Benchmarks/EmbeddingQuality/CoreAI/inspect_parity.py'),
                                     str(corpus), str(root / 'report.json'), str(root / 'reference.json'), str(output),
                                     '--expected-run-id', self.run], capture_output=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIsNone(json.loads(output.read_text())['qualityScores'])


if __name__ == '__main__':
    unittest.main()
