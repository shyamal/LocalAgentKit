"""Offline exact-cosine retrieval quality scoring. No third-party dependencies."""
import argparse
import hashlib
import json
import math
from pathlib import Path


def load_corpus(path):
    raw = Path(path).read_bytes()
    corpus = json.loads(raw)
    if corpus.get('schemaVersion') != 1:
        raise ValueError('Unsupported corpus schema')
    documents, queries = corpus['documents'], corpus['queries']
    if not documents or not queries:
        raise ValueError('Documents and queries must be nonempty')
    ids = [item['id'] for item in documents + queries]
    if any(not isinstance(i, str) or not i for i in ids) or len(set(ids)) != len(ids):
        raise ValueError('IDs must be unique nonempty strings across documents and queries')
    if any(not isinstance(i['text'], str) or not i['text'].strip() for i in documents + queries):
        raise ValueError('Every text must be nonempty')
    document_ids = {i['id'] for i in documents}
    for query in queries:
        relevant = query['relevant']
        if (not isinstance(relevant, list) or not relevant or
                len(set(relevant)) != len(relevant) or not set(relevant) <= document_ids):
            raise ValueError('Every query needs unique, existing relevant document IDs')
    return corpus, hashlib.sha256(raw).hexdigest()


def validate_vectors(export, corpus, digest):
    if export.get('schemaVersion') != 1 or export.get('corpusSHA256') != digest:
        raise ValueError('Vector export schema or corpus hash mismatch')
    if not isinstance(export.get('provider'), str) or not export['provider'].strip():
        raise ValueError('Provider identity is required')
    vectors = export['vectors']
    expected = {i['id'] for i in corpus['documents'] + corpus['queries']}
    if set(vectors) != expected:
        raise ValueError('Vectors must match every corpus ID exactly')
    dimension = None
    normalized = {}
    for identifier, vector in vectors.items():
        if not isinstance(vector, list) or not vector:
            raise ValueError('Empty vector')
        if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v)
               for v in vector):
            raise ValueError('Non-finite or non-numeric vector')
        if dimension is None:
            dimension = len(vector)
        norm = math.hypot(*vector)
        if len(vector) != dimension or not math.isfinite(norm) or norm == 0:
            raise ValueError('Dimension mismatch or zero vector')
        normalized[identifier] = [v / norm for v in vector]
    return normalized


def evaluate(corpus, digest, export, k=3):
    if isinstance(k, bool) or not isinstance(k, int) or k < 1:
        raise ValueError('k must be a positive integer')
    vectors = validate_vectors(export, corpus, digest)
    results = []
    for query in corpus['queries']:
        relevant = set(query['relevant'])
        ranked = sorted(corpus['documents'], key=lambda doc: (
            -math.fsum(a * b for a, b in zip(vectors[query['id']], vectors[doc['id']])), doc['id']))
        ranking = [doc['id'] for doc in ranked]
        top = ranking[:k]
        first = next(index + 1 for index, identifier in enumerate(ranking) if identifier in relevant)
        dcg = sum(1 / math.log2(i + 2) for i, identifier in enumerate(top) if identifier in relevant)
        ideal = sum(1 / math.log2(i + 2) for i in range(min(k, len(relevant))))
        results.append({'id': query['id'], 'category': query.get('category', 'unspecified'),
                        'ranking': ranking, 'recallAtK': len(set(top) & relevant) / len(relevant),
                        'reciprocalRank': 1 / first, 'ndcgAtK': dcg / ideal})
    def average(rows):
        return {key: math.fsum(row[key] for row in rows) / len(rows)
                for key in ('recallAtK', 'reciprocalRank', 'ndcgAtK')}
    return {'schemaVersion': 1, 'corpusSHA256': digest, 'provider': export['provider'],
            'metadata': export.get('metadata', {}), 'k': k, 'documentCount': len(corpus['documents']),
            'queryCount': len(results), 'metrics': average(results),
            'categories': {category: average([r for r in results if r['category'] == category])
                           for category in sorted({r['category'] for r in results})},
            'queries': results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus')
    parser.add_argument('vectors')
    parser.add_argument('output')
    parser.add_argument('--k', type=int, default=3)
    args = parser.parse_args()
    corpus, digest = load_corpus(args.corpus)
    report = evaluate(corpus, digest, json.loads(Path(args.vectors).read_text()), args.k)
    Path(args.output).write_text(json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + '\n')


if __name__ == '__main__':
    main()
