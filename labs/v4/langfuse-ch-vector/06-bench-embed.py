#!/usr/bin/env python3
"""06-bench-embed.py — embed the benchmark corpus once (corpus.bench_texts(), ~108,000 sentences).

The sentences are real Korean text embedded with the same model as the pipeline, not random
vectors; they do not go through Langfuse (100,000 traces would load the shared stack for no
gain — the vectors are the same). Written to .run/bench.npz (vectors float32, texts, intents),
reused by 07-bench.py. The first 200 sentences are the held-out queries.

Usage:  .venv-vector/bin/python labs/v4/langfuse-ch-vector/06-bench-embed.py
"""
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib as L
from corpus import bench_texts

out = os.path.join(L.LAB_DIR, ".run", "bench.npz")
os.makedirs(os.path.dirname(out), exist_ok=True)
items = bench_texts()
texts = [t for t, _ in items]
intents = [k for _, k in items]
print(f"{len(texts)} distinct sentences; model {L.MODEL_ID}@{L.MODEL_REVISION[:7]}")
L.model()
t0 = time.time()
chunks = []
for i in range(0, len(texts), 4096):
    chunks.append(L.embed(texts[i:i + 4096], batch_size=128))
    print(f"  {i + len(chunks[-1])}/{len(texts)}  {time.time() - t0:.0f}s", flush=True)
vecs = np.vstack(chunks).astype(np.float32)
dt = time.time() - t0
np.savez(out, vecs=vecs, texts=np.array(texts), intents=np.array(intents),
         model=np.array(f"{L.MODEL_ID}@{L.MODEL_REVISION}"))
print(f"embedded {len(texts)} in {dt:.0f}s ({len(texts) / dt:.0f}/s), device {L.model().device} -> {out}")
