"""Convert a pinned, unquantized MiniLM checkpoint and prepare exact tensor/reference fixtures."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import sys

MODEL = 'sentence-transformers/all-MiniLM-L6-v2'
REVISION = '1110a243fdf4706b3f48f1d95db1a4f5529b4d41'
TOKENS = 256
TOLERANCE = 1e-4


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus')
    parser.add_argument('output_directory')
    parser.add_argument('--cache-dir', required=True)
    args = parser.parse_args()
    import torch
    from transformers import AutoModel, AutoTokenizer
    from huggingface_hub import snapshot_download
    from coreai_torch import TorchConverter, get_decomp_table
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from score import load_corpus
    corpus, digest = load_corpus(args.corpus)
    output = Path(args.output_directory)
    if output.exists():
        raise ValueError('Output directory must not exist; preserve previous conversion artifacts')
    source = snapshot_download(MODEL, revision=REVISION, cache_dir=args.cache_dir,
                               allow_patterns=['*.json', '*.safetensors', 'vocab.txt'])
    tokenizer = AutoTokenizer.from_pretrained(source, trust_remote_code=False)
    encoder = AutoModel.from_pretrained(source, trust_remote_code=False, use_safetensors=True,
                                        attn_implementation='eager').eval()

    class SentenceEncoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.encoder = encoder

        def forward(self, input_ids, attention_mask):
            hidden = self.encoder(input_ids=input_ids, attention_mask=attention_mask,
                                  return_dict=False)[0]
            mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
            pooled = (hidden * mask).sum(dim=1) / mask.sum(dim=1).clamp(min=1e-9)
            return torch.nn.functional.normalize(pooled, p=2, dim=1)

    model = SentenceEncoder().eval()
    rows = []
    vectors = {}
    for item in corpus['documents'] + corpus['queries']:
        if len(tokenizer.encode(item['text'])) > TOKENS:
            raise ValueError('Strict parity fixture exceeds 256 tokens; no silent truncation')
        tokens = tokenizer(item['text'], return_tensors='pt', padding='max_length',
                           max_length=TOKENS, truncation=False)
        with torch.inference_mode():
            reference = model(tokens['input_ids'], tokens['attention_mask'])[0].tolist()
        rows.append({'id': item['id'], 'inputIDs': tokens['input_ids'][0].tolist(),
                     'attentionMask': tokens['attention_mask'][0].tolist(), 'reference': reference})
        vectors[item['id']] = reference
    sample = (torch.tensor([rows[0]['inputIDs']], dtype=torch.int64),
              torch.tensor([rows[0]['attentionMask']], dtype=torch.int64))
    exported = torch.export.export(model, args=sample)
    exported = exported.run_decompositions(get_decomp_table())
    program = (TorchConverter().add_exported_program(
        exported, input_names=['input_ids', 'attention_mask'], output_names=['embedding']).to_coreai())
    output.mkdir(parents=True)
    asset = output / 'minilm.aimodel'
    program.save_asset(asset)
    metadata = {'model': MODEL, 'revision': REVISION, 'precision': 'unquantized PyTorch float32 source',
                'shape': [1, TOKENS], 'pooling': 'attention-mask mean pooling then L2 normalization',
                'absoluteTolerance': TOLERANCE,
                'packages': {p: importlib.metadata.version(p) for p in ['torch', 'transformers', 'coreai-torch', 'coreai-core']},
                'sourceFilesSHA256': {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
                                      for p in sorted(Path(source).rglob('*')) if p.is_file()},
                'assetFilesSHA256': {str(p.relative_to(asset)): hashlib.sha256(p.read_bytes()).hexdigest()
                                     for p in sorted(asset.rglob('*')) if p.is_file()}}
    fixture = {'schemaVersion': 1, 'corpusSHA256': digest, 'metadata': metadata, 'rows': rows}
    (output / 'fixture.json').write_text(json.dumps(fixture, indent=2, sort_keys=True, allow_nan=False) + '\n')
    reference = {'schemaVersion': 1, 'corpusSHA256': digest, 'provider': MODEL + '/pytorch-fp32',
                 'metadata': metadata, 'vectors': vectors}
    (output / 'reference.json').write_text(json.dumps(reference, indent=2, sort_keys=True, allow_nan=False) + '\n')
    print(f'Converted {len(rows)} fixture rows to {asset}')


if __name__ == '__main__':
    main()
