#!/usr/bin/env python3
"""04-similar.py — "find past traces similar to this failing one".

1. sends one new failing trace (02-seed-traces.py --failing) — a wording that is in no intent list;
2. waits until it is in events_full and runs 03-embed.py, which must pick up exactly this one trace;
3. runs 04-similar.sql for it: the ten nearest past questions, how each ended, and the error
   rate of those neighbours against the error rate of all traces of the lab.

Usage:  .venv-vector/bin/python labs/v4/langfuse-ch-vector/04-similar.py [--trace <id>] [--k 10]
"""
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib as L

ap = argparse.ArgumentParser()
ap.add_argument("--trace", help="search for this trace instead of sending a new failing one")
ap.add_argument("--k", type=int, default=10)
args = ap.parse_args()
py = sys.executable

trace = args.trace
if not trace:
    subprocess.run([py, os.path.join(L.LAB_DIR, "02-seed-traces.py"), "--failing"], check=True)
    trace = open(os.path.join(L.LAB_DIR, ".run", "failing_trace_id")).read().strip()
    for _ in range(60):
        n = L.ch("SELECT count() FROM default.events_full WHERE trace_id = {t:String} AND parent_span_id = ''",
                 params={"t": trace}).strip()
        if n != "0":
            break
        time.sleep(1)
    else:
        sys.exit(f"trace {trace} did not reach events_full within 60 s")
    subprocess.run([py, os.path.join(L.LAB_DIR, "03-embed.py")], check=True)

SQL = f"""
WITH (SELECT vec FROM {L.DB}.embeddings WHERE kind = 'input' AND trace_id = {{t:String}}) AS q
SELECT round(cosineDistance(i.vec, q), 3) AS distance, i.text AS question, i.level AS level,
       i.status_message AS status_message, leftUTF8(o.text, 40) AS answer, i.trace_id AS trace_id
FROM {L.DB}.embeddings AS i
LEFT JOIN (SELECT trace_id, text FROM {L.DB}.embeddings WHERE kind = 'output') AS o USING (trace_id)
WHERE i.kind = 'input' AND i.trace_id != {{t:String}}
ORDER BY cosineDistance(i.vec, q)
LIMIT {{k:UInt32}}
SETTINGS use_skip_indexes = 0   -- exact: a few hundred rows; the index is measured in 07-bench.py
"""
q = L.ch_rows(f"SELECT text, level, status_message FROM {L.DB}.embeddings WHERE kind = 'input' AND trace_id = {{t:String}}",
              params={"t": trace})
if not q:
    sys.exit(f"trace {trace} has no input embedding; run 03-embed.py")
print(f"failing trace {trace}\n  question: {q[0]['text']}\n  {q[0]['level']}: {q[0]['status_message']}\n")
t0 = time.time()
print(L.ch(SQL + " FORMAT PrettyCompactMonoBlock", params={"t": trace, "k": args.k}))
print(f"query {1000 * (time.time() - t0):.0f} ms (client side)")

summary = L.ch_rows(f"""
WITH (SELECT vec FROM {L.DB}.embeddings WHERE kind = 'input' AND trace_id = {{t:String}}) AS q
SELECT
    (SELECT round(countIf(level = 'ERROR') / count(), 3) FROM {L.DB}.embeddings
     WHERE kind = 'input' AND trace_id != {{t:String}}) AS error_rate_all,
    round(countIf(level = 'ERROR') / count(), 3) AS error_rate_neighbours,
    topK(1)(if(status_message = '', NULL, status_message))[1] AS top_status
FROM (SELECT level, status_message FROM {L.DB}.embeddings
      WHERE kind = 'input' AND trace_id != {{t:String}}
      ORDER BY cosineDistance(vec, q) LIMIT {{k:UInt32}} SETTINGS use_skip_indexes = 0)
""", params={"t": trace, "k": args.k})[0]
print(f"error rate of all lab traces {summary['error_rate_all']}, of the {args.k} nearest "
      f"{summary['error_rate_neighbours']}; most common status among them: {summary['top_status']}")

# Free-text search through the HNSW index: a support agent types a question. The WHERE
# (kind = 'input') is applied after the index returned its k nearest rows per part
# (post-filtering), so answer rows among those k are dropped and fewer than k rows come back.
# Two documented ways out: fetch more candidates (vector_search_index_fetch_multiplier) or
# force pre-filtering (an exact scan of the rows that pass the WHERE).
TEXT = "유로로 환전하면 수수료가 얼마나 나와요?"
qv = L.embed([TEXT])[0].tolist()
L.insert_rows(f"{L.DB}.queries", [{"name": "free-text", "text": TEXT, "vec": qv}])
IDX = f"""SELECT round(cosineDistance(vec, {{q:Array(Float32)}}), 3) AS d, text FROM {L.DB}.embeddings
WHERE kind = 'input' ORDER BY cosineDistance(vec, {{q:Array(Float32)}}) LIMIT {{k:UInt32}}"""
print(f"\nfree-text search: {TEXT}")
print(L.ch(IDX + " SETTINGS use_skip_indexes = 0 FORMAT PrettyCompactMonoBlock", params={"q": qv, "k": 5}))
print(f"top-{args.k} with WHERE kind = 'input', through the vector index and exact:")
for label, st in [("index, default settings", {}),
                  ("index, vector_search_index_fetch_multiplier = 4", {"vector_search_index_fetch_multiplier": 4}),
                  ("vector_search_filter_strategy = 'prefilter'", {"vector_search_filter_strategy": "prefilter"}),
                  ("exact (use_skip_indexes = 0)", {"use_skip_indexes": 0})]:
    d = [line.split("\t")[0] for line in L.ch(IDX + " FORMAT TSV", params={"q": qv, "k": args.k}, settings=st).splitlines()]
    print(f"  {label:50s} rows {len(d):2d}  farthest distance {d[-1] if d else '-'}")
