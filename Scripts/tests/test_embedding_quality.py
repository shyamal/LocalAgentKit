import copy
import importlib.util
import json
import math
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('embedding_score', ROOT / 'Benchmarks/EmbeddingQuality/score.py')
score = importlib.util.module_from_spec(spec)
spec.loader.exec_module(score)


class EmbeddingQualityTests(unittest.TestCase):
    def setUp(self):
        self.corpus = {'documents': [{'id': 'a'}, {'id': 'b'}, {'id': 'c'}],
                       'queries': [{'id': 'q', 'relevant': ['a', 'b']}]}
        self.export = {'schemaVersion': 1, 'corpusSHA256': 'hash', 'provider': 'test',
                       'vectors': {'a': [1, 0], 'b': [0, 1], 'c': [-1, 0], 'q': [1, 0]}}

    def test_exact_rank_and_multiple_relevance_metrics(self):
        report = score.evaluate(self.corpus, 'hash', self.export, k=1)
        self.assertEqual(report['queries'][0]['ranking'], ['a', 'b', 'c'])
        self.assertEqual(report['metrics'], {'recallAtK': 0.5, 'reciprocalRank': 1, 'ndcgAtK': 1})

    def test_mrr_is_full_rank_and_ndcg_penalizes_late_hits(self):
        self.corpus['queries'][0]['relevant'] = ['b']
        metrics = score.evaluate(self.corpus, 'hash', self.export, k=2)['metrics']
        self.assertEqual(metrics['reciprocalRank'], 0.5)
        self.assertAlmostEqual(metrics['ndcgAtK'], 1 / math.log2(3))
        self.assertEqual(score.evaluate(self.corpus, 'hash', self.export, k=1)['metrics']['recallAtK'], 0)

    def test_ties_are_id_order_and_vector_scaling_does_not_change_rank(self):
        self.export['vectors']['b'] = [200, 0]
        self.assertEqual(score.evaluate(self.corpus, 'hash', self.export)['queries'][0]['ranking'], ['a', 'b', 'c'])

    def test_invalid_or_mismatched_exports_are_rejected(self):
        changes = [('corpusSHA256', 'other'), ('schemaVersion', 2), ('provider', '')]
        for key, value in changes:
            with self.subTest(key=key), self.assertRaises(ValueError):
                score.evaluate(self.corpus, 'hash', dict(self.export, **{key: value}))
        for vector in [[], [0, 0], [math.nan, 1], [math.inf, 1], [True, 1], [1], ['x', 1]]:
            export = copy.deepcopy(self.export)
            export['vectors']['a'] = vector
            with self.subTest(vector=vector), self.assertRaises(ValueError):
                score.evaluate(self.corpus, 'hash', export)
        export = copy.deepcopy(self.export)
        del export['vectors']['a']
        with self.assertRaises(ValueError):
            score.evaluate(self.corpus, 'hash', export)

    def test_k_must_be_positive_and_can_exceed_corpus(self):
        for k in [0, -1, True, 1.5]:
            with self.assertRaises(ValueError):
                score.evaluate(self.corpus, 'hash', self.export, k)
        self.assertEqual(score.evaluate(self.corpus, 'hash', self.export, 50)['metrics']['recallAtK'], 1)

    def test_corpus_validation_and_original_fixture(self):
        corpus, digest = score.load_corpus(ROOT / 'Benchmarks/EmbeddingQuality/corpus.json')
        self.assertEqual(len(corpus['documents']), 24)
        self.assertEqual(len(corpus['queries']), 20)
        self.assertEqual(len(digest), 64)
        for mutate in ['duplicate', 'missing', 'empty']:
            changed = copy.deepcopy(corpus)
            if mutate == 'duplicate':
                changed['queries'][0]['id'] = changed['documents'][0]['id']
            elif mutate == 'missing':
                changed['queries'][0]['relevant'] = ['absent']
            else:
                changed['documents'] = []
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'corpus.json'
                path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    score.load_corpus(path)

    def test_macro_average_and_category_breakdown(self):
        self.corpus['queries'][0]['category'] = 'first'
        self.corpus['queries'].append({'id': 'q2', 'relevant': ['c'], 'category': 'second'})
        self.export['vectors']['q2'] = [1, 0]
        report = score.evaluate(self.corpus, 'hash', self.export, 1)
        self.assertEqual(report['metrics']['recallAtK'], 0.25)
        self.assertEqual(report['categories']['second']['recallAtK'], 0)


if __name__ == '__main__':
    unittest.main()
