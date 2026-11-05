"""Explicit benchmark-only model download and MLX inference; never imported by the SDK."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import time

MODEL = 'mlx-community/all-MiniLM-L6-v2-4bit'
REVISION = '128ca2da88d925829a17fb5ddfdc86b42eb58fb2'


def encode_input(tokenizer, text, allow_truncation=False):
    inputs = tokenizer.encode(text, return_tensors='mlx')
    length = inputs.shape[-1]
    if length > 256:
        if not allow_truncation:
            raise ValueError('Corpus text exceeds MiniLM sentence-transformer 256-token limit')
        inputs = tokenizer.encode(text, return_tensors='mlx', truncation=True, max_length=256)
        if inputs.shape[-1] > 256:
            raise ValueError('Tokenizer did not honor the requested truncation')
    return inputs, length


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus')
    parser.add_argument('output')
    parser.add_argument('--cache-dir', required=True)
    parser.add_argument('--allow-truncation', action='store_true',
                        help='Explicitly truncate overlength inputs to 256 model tokens and record counts.')
    parser.add_argument('--original-minilm', action='store_true',
                        help='Use the pinned unquantized original checkpoint, not the default 4-bit conversion.')
    args = parser.parse_args()
    model_id, revision = MODEL, REVISION
    if args.original_minilm:
        model_id = 'sentence-transformers/all-MiniLM-L6-v2'
        revision = '1110a243fdf4706b3f48f1d95db1a4f5529b4d41'
    from huggingface_hub import snapshot_download
    import mlx.core as mx
    from mlx_embeddings.utils import load
    from score import load_corpus

    corpus, digest = load_corpus(args.corpus, allow_no_answer=True)
    # Only data/weights/tokenizer files: never download training scripts or execute model code.
    location = snapshot_download(model_id, revision=revision, cache_dir=args.cache_dir,
                                 allow_patterns=['*.json', '*.safetensors', 'vocab.txt'])
    model, tokenizer = load(location, tokenizer_config={'trust_remote_code': False})
    vectors = {}
    truncated = {'documents': 0, 'queries': 0}
    maximum = 0
    document_ids = {item['id'] for item in corpus['documents']}
    start = time.monotonic()
    for item in corpus['documents'] + corpus['queries']:
        inputs, length = encode_input(tokenizer, item['text'], args.allow_truncation)
        maximum = max(maximum, length)
        if length > 256:
            truncated['documents' if item['id'] in document_ids else 'queries'] += 1
        output = model(inputs).text_embeds
        mx.eval(output)
        vectors[item['id']] = output[0].tolist()
    elapsed = time.monotonic() - start
    files = {str(p.relative_to(location)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted(Path(location).rglob('*')) if p.is_file()}
    export = {'schemaVersion': 1, 'corpusSHA256': digest, 'provider': model_id,
              'metadata': {'revision': revision, 'execution': 'MLX Metal, not Core AI',
                           'pooling': 'library BERT mean pooled, normalized text_embeds',
                           'quantization': 'none (original weights)' if args.original_minilm else '4-bit',
                           'truncationAllowed': args.allow_truncation,
                           'truncatedInputs': truncated, 'maximumUntruncatedTokens': maximum, 'os': platform.platform(),
                           'python': platform.python_version(),
                           'packages': {p: importlib.metadata.version(p) for p in
                                        ['mlx', 'mlx-embeddings', 'transformers', 'huggingface-hub']},
                           'filesSHA256': files,
                           'embeddingElapsedSeconds': elapsed},
              'vectors': vectors}
    Path(args.output).write_text(json.dumps(export, allow_nan=False, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
