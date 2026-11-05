import copy
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BENCHMARK = ROOT / 'Benchmarks/EmbeddingQuality'
sys.path.insert(0, str(BENCHMARK))
import score
import score_abstention


class AbstentionTests(unittest.TestCase):
    def setUp(self):
        self.corpus = {'schemaVersion': 1,
                       'documents': [{'id': 'a', 'text': 'First'}, {'id': 'b', 'text': 'Second'}],
                       'queries': [{'id': 'yes', 'text': 'Answerable', 'relevant': ['a']},
                                   {'id': 'no', 'text': 'Unanswerable', 'relevant': [], 'answerable': False}]}
        self.export = {'schemaVersion': 1, 'corpusSHA256': 'hash', 'provider': 'test',
                       'vectors': {'a': [1, 0], 'b': [0, 1], 'yes': [1, 0], 'no': [-1, -1]}}

    def test_known_acceptance_and_abstention_counts(self):
        r = score_abstention.evaluate(self.corpus, 'hash', self.export, 0.5, k=1)
        self.assertEqual(r['counts']['acceptedAnswerable'], 1)
        self.assertEqual(r['counts']['rejectedNoAnswer'], 1)
        self.assertEqual(r['metrics']['noAnswerFalseAcceptRate'], 0)
        self.assertEqual(r['metrics']['acceptedQueryEvidencePrecision'], 1)
        self.assertEqual(r['metrics']['thresholdedRecallAtK'], 1)
        self.assertIsNone(r['queries'][1]['thresholdedRecallAtK'])

    def test_false_acceptance_and_wrong_answerable_hits_are_not_counted_as_support(self):
        self.export['vectors']['no'] = [1, 0]
        self.export['vectors']['yes'] = [0, 1]
        r = score_abstention.evaluate(self.corpus, 'hash', self.export, 0.5, k=1)
        self.assertEqual(r['counts']['acceptedNoAnswer'], 1)
        self.assertEqual(r['counts']['acceptedAnswerableWithoutSupport'], 1)
        self.assertEqual(r['metrics']['noAnswerFalseAcceptRate'], 1)
        self.assertEqual(r['metrics']['acceptedQueryEvidencePrecision'], 0)
        self.assertEqual(r['metrics']['thresholdedRecallAtK'], 0)

    def test_threshold_boundary_and_per_hit_filtering(self):
        r = score_abstention.evaluate(self.corpus, 'hash', self.export, 1.0, k=2)
        self.assertEqual([h['id'] for h in r['queries'][0]['acceptedHits']], ['a'])
        self.assertEqual(r['counts']['acceptedAnswerable'], 1)
        self.export['vectors']['yes'] = [-1, -1]
        r = score_abstention.evaluate(self.corpus, 'hash', self.export, 1.0)
        self.assertEqual(r['metrics']['answerableRejectionRate'], 1)
        self.assertIsNone(r['metrics']['acceptedQueryEvidencePrecision'])
        self.assertEqual(r['metrics']['thresholdedRecallAtK'], 0)

    def test_empty_denominators_are_null_not_fabricated_success(self):
        self.corpus['queries'] = self.corpus['queries'][1:]
        del self.export['vectors']['yes']
        r = score_abstention.evaluate(self.corpus, 'hash', self.export, 1)
        self.assertIsNone(r['metrics']['answerableRejectionRate'])
        self.assertIsNone(r['metrics']['thresholdedRecallAtK'])
        self.corpus['queries'][0]['relevant'] = ['a']
        self.corpus['queries'][0]['answerable'] = True
        r = score_abstention.evaluate(self.corpus, 'hash', self.export, 1)
        self.assertIsNone(r['metrics']['noAnswerFalseAcceptRate'])

    def test_invalid_thresholds_and_vector_exports_fail(self):
        for threshold in [True, math.nan, math.inf, -1.1, 1.1, '0.5']:
            with self.assertRaises(ValueError):
                score_abstention.evaluate(self.corpus, 'hash', self.export, threshold)
        with self.assertRaises(ValueError):
            score_abstention.evaluate(self.corpus, 'hash', self.export, 0.5, k=0)
        with self.assertRaises(ValueError):
            score_abstention.evaluate(self.corpus, 'other-hash', self.export, 0.5)

    def test_no_answer_requires_explicit_opt_in_and_consistent_annotation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'corpus.json'
            path.write_text(json.dumps(self.corpus))
            with self.assertRaises(ValueError):
                score.load_corpus(path)
            score.load_corpus(path, allow_no_answer=True)
            for annotation in [None, True, 'false', 0]:
                changed = copy.deepcopy(self.corpus)
                if annotation is None:
                    del changed['queries'][1]['answerable']
                else:
                    changed['queries'][1]['answerable'] = annotation
                path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    score.load_corpus(path, allow_no_answer=True)
            self.corpus['queries'][0]['answerable'] = False
            path.write_text(json.dumps(self.corpus))
            with self.assertRaises(ValueError):
                score.load_corpus(path, allow_no_answer=True)

    def test_fixture_keeps_original_answerable_queries_and_fixed_threshold_plan(self):
        original, _ = score.load_corpus(BENCHMARK / 'corpus.json')
        fixture, _ = score.load_corpus(BENCHMARK / 'corpus-no-answer.json', allow_no_answer=True)
        self.assertEqual(fixture['documents'], original['documents'])
        self.assertEqual([{k: v for k, v in q.items() if k != 'answerable'}
                          for q in fixture['queries'][:20]], original['queries'])
        self.assertEqual(len(fixture['queries']), 30)
        self.assertEqual(fixture['evaluationPlan']['thresholds'], [0.0, 0.5, 0.75])


if __name__ == '__main__':
    unittest.main()
