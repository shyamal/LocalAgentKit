import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('retrieval_scale', ROOT / 'Benchmarks/RetrievalScale/run.py')
scale = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scale)


class RetrievalScaleTests(unittest.TestCase):
    def workload(self):
        return {'stores': ['memory'], 'counts': [4], 'dimensions': [2], 'repetitions': 2,
                'queries': 2, 'warmups': 1, 'candidateLimit': 2,
                'hostAssessment': {'count': 4, 'warmQueryP95Milliseconds': 100}}

    def row(self, repetition=0):
        return {'schemaVersion': 1, 'operation': 'query', 'store': 'memory', 'count': 4,
                'dimensions': 2, 'searchMilliseconds': [10, 20], 'resultCount': 6,
                'initializationMilliseconds': 1, 'loadMilliseconds': None,
                'maximumResidentBytes': 100, 'peakFootprintBytes': 80, 'snapshotBytes': 0,
                'fitsDefaultFileBudget': True, 'repetition': repetition}

    def test_nearest_rank_percentiles_and_invalid_samples(self):
        self.assertEqual(scale.percentile([9, 1, 4, 2], .5), 2)
        self.assertEqual(scale.percentile([9, 1, 4, 2], .95), 9)
        for values in [[], [-1], [float('nan')], [float('inf')]]:
            with self.assertRaises(ValueError):
                scale.percentile(values, .95)

    def test_memory_metrics_require_both_exact_positive_fields(self):
        text = '   100 maximum resident set size\n   80 peak memory footprint\n'
        self.assertEqual(scale.memory_metrics(text), {'maximumResidentBytes': 100, 'peakFootprintBytes': 80})
        for invalid in ['', text + text, text.replace('100', '0'), text.replace('80', '-1')]:
            with self.assertRaises(ValueError):
                scale.memory_metrics(invalid)

    def test_native_output_must_match_request_and_sample_count(self):
        case = {'store': 'memory', 'count': 4, 'dimensions': 2}
        row = self.row()
        self.assertEqual(scale.validate_report(row, self.workload(), case, 'query'), row)
        for key, value in [('count', 3), ('dimensions', 4), ('store', 'file'),
                           ('operation', 'prepare'), ('schemaVersion', 2),
                           ('searchMilliseconds', [1]), ('resultCount', 0),
                           ('initializationMilliseconds', float('nan'))]:
            invalid = {**row, key: value}
            with self.assertRaises(ValueError, msg=key):
                scale.validate_report(invalid, self.workload(), case, 'query')

    def test_file_queries_require_explicit_load_timing(self):
        case = {'store': 'file', 'count': 4, 'dimensions': 2}
        row = {**self.row(), 'store': 'file'}
        with self.assertRaises(ValueError):
            scale.validate_report(row, self.workload(), case, 'query')
        row['loadMilliseconds'] = 2
        scale.validate_report(row, self.workload(), case, 'query')

    def test_summary_keeps_all_samples_and_high_water_memory(self):
        rows = [self.row(0), {**self.row(1), 'searchMilliseconds': [30, 40], 'maximumResidentBytes': 200}]
        result = scale.summarize(rows, self.workload())[0]
        self.assertEqual(result['samples'], 4)
        self.assertEqual(result['queryP50Milliseconds'], 20)
        self.assertEqual(result['queryP95Milliseconds'], 40)
        self.assertEqual(result['maximumResidentBytes'], 200)
        self.assertFalse(result['annInvestigationWarranted'])

    def test_missing_cases_repeats_or_duplicate_repeats_cannot_pass(self):
        for rows in [[], [self.row(0)], [self.row(0), self.row(0)]]:
            with self.assertRaises(ValueError):
                scale.summarize(rows, self.workload())
        workload = self.workload()
        workload['counts'].append(100)
        with self.assertRaises(ValueError):
            scale.summarize([self.row(0), self.row(1)], workload)

    def test_committed_summary_recomputes_from_every_raw_run(self):
        root = ROOT / 'Benchmarks/RetrievalScale/results/macos-2026-11-06'
        manifest = json.loads((root / 'manifest.json').read_text())
        workload = manifest['workload']
        raw = json.loads((root / 'runs.json').read_text())
        summary = json.loads((root / 'summary.json').read_text())
        for row in raw['runs']:
            case = {key: row[key] for key in ['store', 'count', 'dimensions']}
            scale.validate_report(row, workload, case, 'query')
        self.assertEqual(len(raw['preparations']), 8)
        self.assertEqual(len(raw['runs']), 48)
        self.assertEqual(scale.summarize(raw['runs'], workload), summary)

    def test_ann_rule_requires_two_repeats_and_only_applies_at_pinned_size(self):
        workload = self.workload()
        slow = {**self.row(0), 'searchMilliseconds': [101, 102]}
        self.assertFalse(scale.summarize([slow, self.row(1)], workload)[0]['annInvestigationWarranted'])
        self.assertTrue(scale.summarize([slow, {**slow, 'repetition': 1}], workload)[0]['annInvestigationWarranted'])
        workload['hostAssessment']['count'] = 5
        self.assertFalse(scale.summarize([slow, {**slow, 'repetition': 1}], workload)[0]['annInvestigationWarranted'])
