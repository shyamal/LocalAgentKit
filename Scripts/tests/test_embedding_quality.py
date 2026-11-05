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



class IndependentCorpusTests(unittest.TestCase):
    def module(self, name, file):
        module_spec = importlib.util.spec_from_file_location(name, ROOT / 'Benchmarks/EmbeddingQuality' / file)
        module = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)
        return module

    def test_checksum_failure_happens_before_archive_parsing(self):
        prepare = self.module('prepare_scifact', 'prepare_scifact.py')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'archive.zip'
            path.write_bytes(b'not an archive')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                prepare.convert(path)

    def source_archive(self, directory, qrel='q\td\t1\n', duplicate=False):
        import zipfile
        prepare = self.module('prepare_scifact_fixture', 'prepare_scifact.py')
        path = Path(directory) / 'fixture.zip'
        doc = json.dumps({'_id': 'd', 'title': 'Title', 'text': 'Full abstract'}) + '\n'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('scifact/corpus.jsonl', doc * (2 if duplicate else 1) +
                             json.dumps({'_id': 'unjudged', 'title': '', 'text': 'Distractor'}) + '\n')
            archive.writestr('scifact/queries.jsonl', json.dumps({'_id': 'q', 'text': 'Claim'}) + '\n' +
                             json.dumps({'_id': 'train-only', 'text': 'Not in test'}) + '\n')
            archive.writestr('scifact/qrels/test.tsv', 'query-id\tcorpus-id\tscore\n' + qrel)
            archive.writestr('../../must-not-extract', 'unrelated member')
        import hashlib
        prepare.SHA256 = hashlib.sha256(path.read_bytes()).hexdigest()
        return prepare, path

    def test_full_candidates_and_only_test_queries_are_imported_without_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            prepare, path = self.source_archive(directory)
            corpus = prepare.convert(path)
            self.assertEqual(corpus['documents'], [{'id': 'd-d', 'text': 'Title\nFull abstract'},
                                                   {'id': 'd-unjudged', 'text': 'Distractor'}])
            self.assertEqual(corpus['queries'], [{'id': 'q-q', 'text': 'Claim', 'relevant': ['d-d'], 'category': 'scifact-test'}])
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_missing_relevance_ids_and_duplicate_source_documents_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            for qrel, duplicate in [('q\tmissing\t1\n', False), ('missing\td\t1\n', False), ('q\td\t1\n', True)]:
                prepare, path = self.source_archive(directory, qrel, duplicate)
                with self.assertRaises(ValueError):
                    prepare.convert(path)

    def test_compact_rankings_do_not_change_metrics_or_full_first_relevant_rank(self):
        fixture = EmbeddingQualityTests()
        fixture.setUp()
        fixture.corpus['queries'][0]['relevant'] = ['c']
        full = score.evaluate(fixture.corpus, 'hash', fixture.export, k=1)
        compact = score.evaluate(fixture.corpus, 'hash', fixture.export, k=1, ranking_limit=1)
        self.assertEqual(full['metrics'], compact['metrics'])
        self.assertEqual(compact['queries'][0]['firstRelevantRank'], 3)
        self.assertEqual(compact['queries'][0]['ranking'], ['a'])
        for limit in [0, True, 0.5]:
            with self.assertRaises(ValueError):
                score.evaluate(fixture.corpus, 'hash', fixture.export, ranking_limit=limit)

    def test_long_input_requires_opt_in_and_truncation_is_verified(self):
        exporter = self.module('export_mlx', 'export_mlx.py')
        class Tokens:
            def __init__(self, length):
                self.shape = (1, length)
        class Tokenizer:
            def encode(self, text, **kwargs):
                return Tokens(kwargs.get('max_length', 300))
        with self.assertRaisesRegex(ValueError, '256-token'):
            exporter.encode_input(Tokenizer(), 'long')
        tokens, length = exporter.encode_input(Tokenizer(), 'long', True)
        self.assertEqual(length, 300)
        self.assertEqual(tokens.shape, (1, 256))
        class BrokenTokenizer:
            def encode(self, text, **kwargs):
                return Tokens(300)
        with self.assertRaisesRegex(ValueError, 'honor'):
            exporter.encode_input(BrokenTokenizer(), 'long', True)


if __name__ == '__main__':
    unittest.main()
