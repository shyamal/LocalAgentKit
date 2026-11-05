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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus')
    parser.add_argument('output')
    parser.add_argument('--cache-dir', required=True)
    args = parser.parse_args()
    from huggingface_hub import snapshot_download
    import mlx.core as mx
    from mlx_embeddings.utils import load
    from score import load_corpus

    corpus, digest = load_corpus(args.corpus)
    # Only data/weights/tokenizer files: never download training scripts or execute model code.
    location = snapshot_download(MODEL, revision=REVISION, cache_dir=args.cache_dir,
                                 allow_patterns=['*.json', '*.safetensors', 'vocab.txt'])
    model, tokenizer = load(location, tokenizer_config={'trust_remote_code': False})
    vectors = {}
    start = time.monotonic()
    for item in corpus['documents'] + corpus['queries']:
        inputs = tokenizer.encode(item['text'], return_tensors='mlx')
        if inputs.shape[-1] > 256:
            raise ValueError('Corpus text exceeds MiniLM sentence-transformer 256-token limit')
        output = model(inputs).text_embeds
        mx.eval(output)
        vectors[item['id']] = output[0].tolist()
    elapsed = time.monotonic() - start
    files = {str(p.relative_to(location)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted(Path(location).rglob('*')) if p.is_file()}
    export = {'schemaVersion': 1, 'corpusSHA256': digest, 'provider': MODEL,
              'metadata': {'revision': REVISION, 'execution': 'MLX Metal, not Core AI',
                           'pooling': 'library BERT mean pooled, normalized text_embeds',
                           'quantization': '4-bit', 'os': platform.platform(),
                           'python': platform.python_version(),
                           'packages': {p: importlib.metadata.version(p) for p in
                                        ['mlx', 'mlx-embeddings', 'transformers', 'huggingface-hub']},
                           'filesSHA256': files,
                           'embeddingElapsedSeconds': elapsed},
              'vectors': vectors}
    Path(args.output).write_text(json.dumps(export, allow_nan=False, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
