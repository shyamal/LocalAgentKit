import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Benchmarks/EmbeddingQuality'))
import inspect_device


class DeviceReportTests(unittest.TestCase):
    def setUp(self):
        self.corpus = {'documents': [{'id': 'd'}], 'queries': [{'id': 'q', 'relevant': ['d']}]}
        self.report = {'schemaVersion': 1, 'corpusSHA256': 'hash',
                       'runID': '05C471EF-4DA1-4BBE-B692-2A71586C5D03', 'results': []}
        for name in sorted(inspect_device.PATHS):
            self.report['results'].append({'path': name, 'status': 'completed',
                'export': {'schemaVersion': 1, 'corpusSHA256': 'hash', 'provider': name,
                           'vectors': {'d': [1, 0], 'q': [1, 0]}}})

    def test_scores_complete_paths_and_reports_multiple_matches_without_guessing(self):
        result = inspect_device.inspect(self.corpus, 'hash', self.report, self.report['runID'].lower())
        self.assertEqual(len(result['scores']), 3)
        self.assertEqual(result['sdkVectorMatches'], ['natural-language-sentence', 'natural-language-word-average'])
        self.assertEqual(result['scores']['sdk-default']['metrics']['recallAtK'], 1)

    def test_unavailable_and_failed_paths_are_not_scored_or_matched(self):
        for row in self.report['results']:
            if row['path'] == 'natural-language-sentence':
                row['status'] = 'unavailable'
                del row['export']
        result = inspect_device.inspect(self.corpus, 'hash', self.report)
        self.assertEqual(result['sdkVectorMatches'], ['natural-language-word-average'])
        self.assertNotIn('natural-language-sentence', result['scores'])
        for row in self.report['results']:
            if row['path'] == 'sdk-default':
                row['status'] = 'failed'
                del row['export']
        self.assertEqual(inspect_device.inspect(self.corpus, 'hash', self.report)['sdkVectorMatches'], [])

    def test_stale_corrupt_duplicate_and_partial_reports_are_rejected(self):
        with self.assertRaises(ValueError):
            inspect_device.inspect(self.corpus, 'other', self.report)
        with self.assertRaisesRegex(ValueError, 'Stale'):
            inspect_device.inspect(self.corpus, 'hash', self.report, '00000000-0000-4000-8000-000000000001')
        bad = copy.deepcopy(self.report)
        bad['results'][0]['status'] = 'unavailable'
        with self.assertRaises(ValueError):
            inspect_device.inspect(self.corpus, 'hash', bad)
        bad = copy.deepcopy(self.report)
        bad['results'][0]['export']['vectors']['q'] = [0, 0]
        with self.assertRaises(ValueError):
            inspect_device.inspect(self.corpus, 'hash', bad)
        bad = copy.deepcopy(self.report)
        bad['results'].append(bad['results'][0])
        with self.assertRaises(ValueError):
            inspect_device.inspect(self.corpus, 'hash', bad)


if __name__ == '__main__':
    unittest.main()
