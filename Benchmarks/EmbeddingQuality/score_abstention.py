"""Measure explicit cosine-threshold evidence acceptance; not answer correctness or calibration."""
import argparse
import json
import math
from pathlib import Path

from score import load_corpus, validate_vectors


def evaluate(corpus, digest, export, threshold, k=3):
    if (isinstance(threshold, bool) or not isinstance(threshold, (int, float)) or
            not math.isfinite(threshold) or not -1 <= threshold <= 1):
        raise ValueError('threshold must be finite and within [-1, 1]')
    if type(k) is not int or k < 1:
        raise ValueError('k must be a positive integer')
    vectors = validate_vectors(export, corpus, digest)
    results = []
    for query in corpus['queries']:
        relevant = set(query['relevant'])
        if not relevant and query.get('answerable') is not False:
            raise ValueError('Empty relevance requires explicit answerable=false')
        if relevant and query.get('answerable') is False:
            raise ValueError('No-answer queries cannot have supporting passage IDs')
        ranked = sorted(({'id': doc['id'], 'score': math.fsum(
            a * b for a, b in zip(vectors[query['id']], vectors[doc['id']]))}
                         for doc in corpus['documents']), key=lambda hit: (-hit['score'], hit['id']))
        accepted = [hit for hit in ranked[:k] if hit['score'] >= threshold]
        hit_count = len({hit['id'] for hit in accepted} & relevant)
        results.append({'id': query['id'], 'answerable': bool(relevant),
                        'topScore': ranked[0]['score'], 'acceptedHits': accepted,
                        'accepted': bool(accepted), 'supportingHitCount': hit_count,
                        'thresholdedRecallAtK': hit_count / len(relevant) if relevant else None})
    positives = [r for r in results if r['answerable']]
    negatives = [r for r in results if not r['answerable']]
    accepted_count = sum(r['accepted'] for r in results)
    false_accepts = sum(r['accepted'] for r in negatives)
    rejected_positives = sum(not r['accepted'] for r in positives)
    accepted_with_support = sum(r['supportingHitCount'] > 0 for r in positives)
    return {'schemaVersion': 1, 'task': 'cosine-threshold-evidence-acceptance',
            'corpusSHA256': digest, 'provider': export['provider'],
            'metadata': export.get('metadata', {}), 'threshold': threshold, 'k': k,
            'documentCount': len(corpus['documents']), 'queryCount': len(results),
            'answerableQueryCount': len(positives), 'noAnswerQueryCount': len(negatives),
            'counts': {'acceptedAnswerable': len(positives) - rejected_positives,
                       'rejectedAnswerable': rejected_positives,
                       'acceptedNoAnswer': false_accepts,
                       'rejectedNoAnswer': len(negatives) - false_accepts,
                       'acceptedWithSupportingHit': accepted_with_support,
                       'acceptedAnswerableWithoutSupport': len(positives) - rejected_positives - accepted_with_support},
            'metrics': {'noAnswerFalseAcceptRate': false_accepts / len(negatives) if negatives else None,
                        'answerableRejectionRate': rejected_positives / len(positives) if positives else None,
                        'acceptedQueryEvidencePrecision': accepted_with_support / accepted_count if accepted_count else None,
                        'thresholdedRecallAtK': math.fsum(r['thresholdedRecallAtK'] for r in positives) / len(positives) if positives else None},
            'queries': results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus')
    parser.add_argument('vectors')
    parser.add_argument('output')
    parser.add_argument('--threshold', required=True, type=float)
    parser.add_argument('--k', type=int, default=3)
    args = parser.parse_args()
    corpus, digest = load_corpus(args.corpus, allow_no_answer=True)
    result = evaluate(corpus, digest, json.loads(Path(args.vectors).read_text()), args.threshold, args.k)
    Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + '\n')


if __name__ == '__main__':
    main()
