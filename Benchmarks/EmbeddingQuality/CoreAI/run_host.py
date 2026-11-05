"""Run the converted artifact with Apple's Python Core AI runtime; emit only after raw parity passes."""
import argparse
import asyncio
import json
import math
from pathlib import Path
import platform
import sys
from uuid import UUID, uuid4

from convert_minilm import MODEL, REVISION, TOKENS, TOLERANCE


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus')
    parser.add_argument('conversion_directory')
    parser.add_argument('output')
    parser.add_argument('--run-id', default=str(uuid4()))
    args = parser.parse_args()
    asyncio.run(run(args))


async def run(args):
    import numpy as np
    from coreai.authoring import AIModelAsset
    from coreai.runtime import NDArray
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from score import load_corpus, validate_vectors
    corpus, digest = load_corpus(args.corpus)
    directory = Path(args.conversion_directory)
    output = Path(args.output)
    if output.exists():
        raise ValueError('Output must not exist; do not mistake a stale report for success')
    fixture = json.loads((directory / 'fixture.json').read_text())
    reference = json.loads((directory / 'reference.json').read_text())
    validate_vectors(reference, corpus, digest)
    expected = {r['id'] for r in corpus['documents'] + corpus['queries']}
    if (fixture['schemaVersion'] != 1 or fixture['corpusSHA256'] != digest or
            fixture['metadata']['revision'] != REVISION or fixture['metadata']['model'] != MODEL or
            len(fixture['rows']) != len(expected) or {r['id'] for r in fixture['rows']} != expected):
        raise ValueError('Conversion fixture provenance/coverage mismatch')
    asset = AIModelAsset.load(directory / 'minilm.aimodel')
    vectors = {}
    maximum = 0
    async with asset.executable() as model:
        function = model.load_function('main')
        for row in fixture['rows']:
            if (len(row['inputIDs']) != TOKENS or len(row['attentionMask']) != TOKENS or
                    any(type(i) is not int or i < 0 or i > 2 ** 31 - 1 for i in row['inputIDs']) or
                    any(type(i) is not int or i not in (0, 1) for i in row['attentionMask'])):
                raise ValueError('Invalid int32 tensor fixture')
            result = await function({
                'input_ids': NDArray(np.array([row['inputIDs']], dtype=np.int32)),
                'attention_mask': NDArray(np.array([row['attentionMask']], dtype=np.int32))})
            value = result['embedding'].numpy()
            if value.shape != (1, 384) or value.dtype != np.float32 or not np.isfinite(value).all():
                raise ValueError('Invalid output shape/components')
            vector = value[0].tolist()
            maximum = max(maximum, max(abs(a - b) for a, b in zip(vector, reference['vectors'][row['id']])))
            vectors[row['id']] = vector
    if maximum > TOLERANCE or any(abs(math.hypot(*v) - 1) > 1e-4 for v in vectors.values()):
        raise ValueError('Numerical parity/normalization failed; no vectors published')
    metadata = dict(fixture['metadata'], execution='Official coreai-core Python runtime, default specialization',
                    hostOS=platform.platform(), coreAIInputScalarType='int32', coreAIOutputScalarType='float32')
    report = {'schemaVersion': 1, 'runID': str(UUID(args.run_id)), 'corpusSHA256': digest,
              'metadata': {'executionKind': 'coreai-python-host', 'os': platform.platform()},
              'coreAI': {'status': 'completed', 'failure': None, 'comparedVectorCount': len(vectors),
                         'maximumAbsoluteError': maximum, 'metadata': metadata,
                         'export': {'schemaVersion': 1, 'corpusSHA256': digest,
                                    'provider': 'minilm-coreai-python-fp32', 'metadata': metadata, 'vectors': vectors}}}
    output.write_text(json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + '\n')
    print(f'Core AI parity passed for {len(vectors)} vectors; maximum absolute error {maximum}')


if __name__ == '__main__':
    main()
