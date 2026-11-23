#!/usr/bin/env python3
"""05-topics.py — group the lab's traces into topics by their question embeddings.

1. reads the input vectors of every embedded trace from ClickHouse;
2. k-means (scikit-learn, cosine via L2-normalised vectors) for k in --k-range, keeps the k
   with the best silhouette score;
3. names each topic by the question closest to its centroid;
4. writes lab_langfuse_ch_vector.topics (one run_id per run) and, with --scores, a categorical
   score `topic` on each trace in Langfuse, so the topic can be filtered in the Langfuse UI;
5. prints per topic: traces, error rate, most common status message — and, only to grade the
   clustering, its agreement with the seed intent in metadata (adjusted Rand index, purity).

Usage:  .venv-vector/bin/python labs/v4/langfuse-ch-vector/05-topics.py [--scores] [--k-range 6 20]
"""
import argparse
import collections
import datetime
import os
import sys

import numpy as np
from sklearn.cluster import KMeans
from sklearn.metrics import adjusted_rand_score, silhouette_score

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib as L

ap = argparse.ArgumentParser()
ap.add_argument("--k-range", type=int, nargs=2, default=[6, 20])
ap.add_argument("--scores", action="store_true", help="also write a `topic` score per trace to Langfuse")
args = ap.parse_args()

rows = L.ch_rows(f"SELECT trace_id, text, level, status_message, vec FROM {L.DB}.embeddings "
                 "WHERE kind = 'input' ORDER BY trace_id")
X = np.array([r["vec"] for r in rows], dtype=np.float32)
print(f"{len(rows)} traces, {X.shape[1]} dimensions")

best = None
for k in range(args.k_range[0], args.k_range[1] + 1):
    km = KMeans(n_clusters=k, n_init=10, random_state=0).fit(X)
    s = silhouette_score(X, km.labels_, metric="cosine")
    print(f"  k={k:2d} silhouette={s:.3f}")
    if best is None or s > best[1]:
        best = (k, s, km)
k, sil, km = best
print(f"chosen k={k} (silhouette {sil:.3f})")

C = km.cluster_centers_ / np.linalg.norm(km.cluster_centers_, axis=1, keepdims=True)
dist = 1 - np.sum(X * C[km.labels_], axis=1)
labels = {}
for c in range(k):
    idx = np.where(km.labels_ == c)[0]
    labels[c] = rows[idx[np.argmin(dist[idx])]]["text"]

run_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
L.insert_rows(f"{L.DB}.topics", [{"run_id": run_id, "trace_id": r["trace_id"], "topic": int(c),
                                  "topic_label": labels[int(c)], "distance": float(d)}
                                 for r, c, d in zip(rows, km.labels_, dist)])
print(f"wrote {len(rows)} rows to {L.DB}.topics, run_id {run_id}\n")

print(L.ch(f"""
SELECT t.topic, any(t.topic_label) AS topic_label, count() AS traces,
       round(countIf(e.level = 'ERROR') / count(), 2) AS error_rate,
       topK(1)(if(e.status_message = '', NULL, e.status_message))[1] AS top_status
FROM {L.DB}.topics AS t
JOIN {L.DB}.embeddings AS e ON e.trace_id = t.trace_id AND e.kind = 'input'
WHERE t.run_id = {{run:String}}
GROUP BY t.topic ORDER BY error_rate DESC, traces DESC
FORMAT PrettyCompactMonoBlock""", params={"run": run_id}))

# Grading only: the intent each wording was seeded from (metadata seed_intent).
truth = {r["trace_id"]: r["intent"] for r in L.ch_rows(
    "SELECT trace_id, metadata_values[indexOf(metadata_names, 'seed_intent')] AS intent "
    "FROM default.events_full WHERE has(tags, {tag:String}) AND parent_span_id = '' "
    "LIMIT 1 BY trace_id", params={"tag": L.LAB_TAG})}
y_true = [truth.get(r["trace_id"], "?") for r in rows]
ari = adjusted_rand_score(y_true, km.labels_)
purity = sum(collections.Counter(t for t, c in zip(y_true, km.labels_) if c == cl).most_common(1)[0][1]
             for cl in range(k)) / len(rows)
print(f"against the seed intents ({len(set(y_true))}): adjusted Rand index {ari:.3f}, purity {purity:.3f}")

if args.scores:
    from langfuse import Langfuse
    lf = Langfuse(base_url=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
                  public_key=os.environ["LANGFUSE_PUBLIC_KEY"], secret_key=os.environ["LANGFUSE_SECRET_KEY"])
    for r, c in zip(rows, km.labels_):
        lf.create_score(name="topic", value=f"{int(c):02d} {labels[int(c)][:40]}", trace_id=r["trace_id"],
                        data_type="CATEGORICAL", comment=f"05-topics.py run {run_id}")
    lf.flush()
    print(f"wrote {len(rows)} `topic` scores to Langfuse")
