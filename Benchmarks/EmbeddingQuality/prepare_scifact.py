"""Convert a checksum-pinned, user-downloaded BEIR SciFact archive; no network or extraction."""
import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import zipfile

URL = 'https://public.ukp.informatik.tu-darmstadt.de/thakur/BEIR/datasets/scifact.zip'
SHA256 = '536e14446a0ba56ed1398ab1055f39fe852686ecad24a6306c80c490fa8e0165'


def convert(archive):
    raw = Path(archive).read_bytes()
    if hashlib.sha256(raw).hexdigest() != SHA256:
        raise ValueError('SciFact archive checksum mismatch')
    with zipfile.ZipFile(io.BytesIO(raw)) as bundle:
        # Read exact members in memory; no archive paths are extracted to disk.
        documents = [json.loads(line) for line in bundle.read('scifact/corpus.jsonl').decode().splitlines()]
        queries = [json.loads(line) for line in bundle.read('scifact/queries.jsonl').decode().splitlines()]
        rows = csv.DictReader(io.StringIO(bundle.read('scifact/qrels/test.tsv').decode()), delimiter='\t')
        qrels = {}
        for row in rows:
            if int(row['score']) > 0:
                qrels.setdefault(row['query-id'], set()).add(row['corpus-id'])
    doc_ids = [d['_id'] for d in documents]
    query_ids = [q['_id'] for q in queries]
    if len(set(doc_ids)) != len(doc_ids) or len(set(query_ids)) != len(query_ids):
        raise ValueError('Duplicate source IDs')
    if not set(qrels) <= set(query_ids) or any(not ids <= set(doc_ids) for ids in qrels.values()):
        raise ValueError('Missing query or document referenced by test qrels')
    return {'schemaVersion': 1,
            'description': 'BEIR SciFact full corpus, all positive-qrel test queries; published binary qrels; no custom labels.',
            'provenance': {'url': URL, 'archiveSHA256': SHA256, 'split': 'test',
                           'documentText': 'nonempty title and text joined with one newline; no prefixing or chunking'},
            'documents': [{'id': 'd-' + d['_id'], 'text': '\n'.join(
                part for part in [d.get('title', ''), d['text']] if part)} for d in sorted(documents, key=lambda d: d['_id'])],
            'queries': [{'id': 'q-' + q['_id'], 'text': q['text'],
                         'relevant': ['d-' + d for d in sorted(qrels[q['_id']])], 'category': 'scifact-test'}
                        for q in sorted(queries, key=lambda q: q['_id']) if q['_id'] in qrels]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive')
    parser.add_argument('output')
    args = parser.parse_args()
    result = convert(args.archive)
    Path(args.output).write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print(f"Prepared {len(result['documents'])} documents and {len(result['queries'])} test queries")


if __name__ == '__main__':
    main()
