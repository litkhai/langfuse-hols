#!/usr/bin/env python3
"""03-embed.py — incremental embedding pipeline: Langfuse events_full → lab_langfuse_ch_vector.embeddings.

Each run:
  1. reads the watermark (the largest events_full.event_ts the last run saw);
  2. selects root observations (parent_span_id = '', i.e. the trace) with event_ts later than
     the watermark minus an overlap window, newest version per span_id, input and output as
     two rows, minus the (span_id, kind) pairs that are already embedded;
  3. embeds the text locally and inserts Array(Float32) rows;
  4. moves the watermark.

Why the overlap: event_ts is written by the Langfuse worker, and two worker batches can become
visible in ClickHouse out of order. Re-reading the last few minutes and skipping what is
already embedded (the NOT IN) costs little and loses nothing. Why events_full and not
events_core: events_core keeps only the first 200 characters of input and output
(`leftUTF8(input, 200)` in events_core_mv, read from the live schema).

Usage:
    .venv-vector/bin/python labs/v4/langfuse-ch-vector/03-embed.py              # this lab's traces only
    .venv-vector/bin/python labs/v4/langfuse-ch-vector/03-embed.py --tag ''     # every trace of the project
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib as L

ap = argparse.ArgumentParser()
ap.add_argument("--tag", default=L.LAB_TAG, help="only traces with this tag; '' = all")
ap.add_argument("--overlap-seconds", type=int, default=300)
ap.add_argument("--max-rows", type=int, default=20000, help="per run; the next run continues")
args = ap.parse_args()

PIPELINE = "root-io"
wm = L.ch_rows(f"SELECT toString(event_ts) AS ts FROM {L.DB}.watermark FINAL WHERE pipeline = {{p:String}}",
               params={"p": PIPELINE})
watermark = wm[0]["ts"] if wm else "1970-01-01 00:00:00.000000"

tag_filter = "AND has(tags, {tag:String})" if args.tag else ""
SELECT = f"""
SELECT project_id, trace_id, span_id, name, level, status_message,
       toString(start_time) AS start_time, toString(event_ts) AS event_ts, kind, value
FROM
(
    SELECT *
    FROM default.events_full
    WHERE project_id = {{project:String}}
      AND parent_span_id = ''
      AND event_ts > {{since:DateTime64(6)}} - toIntervalSecond({{overlap:UInt32}})
      {tag_filter}
    ORDER BY span_id, event_ts DESC
    LIMIT 1 BY span_id
)
ARRAY JOIN ['input', 'output'] AS kind, [input, output] AS value
WHERE is_deleted = 0              -- after LIMIT 1 BY: a deletion is the newest version of the row
  AND value NOT IN ('', 'null', '{{}}')
  AND (span_id, kind) NOT IN (SELECT span_id, kind FROM {L.DB}.embeddings WHERE project_id = {{project:String}})
ORDER BY event_ts
LIMIT {{max_rows:UInt32}}
"""
t0 = time.time()
rows = L.ch_rows(SELECT, params={"project": L.PROJECT_ID, "since": watermark, "overlap": args.overlap_seconds,
                                 "tag": args.tag, "max_rows": args.max_rows})
t_read = time.time() - t0

texts = [L.text_of(r["value"]) or r["value"] for r in rows]
t1 = time.time()
if rows:
    L.model()            # load once per run (from the local Hugging Face cache)
t_load = time.time() - t1
t1 = time.time()
vecs = L.embed(texts) if rows else []
t_embed = time.time() - t1

model_name = f"{L.MODEL_ID}@{L.MODEL_REVISION[:7]}"
out = [{
    "project_id": r["project_id"], "trace_id": r["trace_id"], "span_id": r["span_id"], "kind": r["kind"],
    "name": r["name"], "level": r["level"], "status_message": r["status_message"],
    "start_time": r["start_time"], "event_ts": r["event_ts"], "text": t, "model": model_name,
    "vec": [round(float(x), 7) for x in v],
} for r, t, v in zip(rows, texts, vecs)]
t2 = time.time()
for i in range(0, len(out), 500):
    L.insert_rows(f"{L.DB}.embeddings", out[i:i + 500])
t_insert = time.time() - t2

new_wm = max([r["event_ts"] for r in rows] + [watermark])
L.insert_rows(f"{L.DB}.watermark", [{"pipeline": PIPELINE, "event_ts": new_wm,
                                     "rows_read": len(rows), "rows_added": len(out)}])
# Deletions: Langfuse removes a deleted trace's rows from events_full (DELETE, a minute or two after
# the API call, measured 2026-11-23). Remove its vectors too, so a deleted trace is never "similar".
STALE = f"""project_id = {{project:String}} AND trace_id NOT IN
    (SELECT trace_id FROM default.events_full WHERE project_id = {{project:String}} AND parent_span_id = '')"""
stale = int(L.ch(f"SELECT count() FROM {L.DB}.embeddings WHERE {STALE}", params={"project": L.PROJECT_ID}).strip())
if stale:
    L.ch(f"DELETE FROM {L.DB}.embeddings WHERE {STALE}", params={"project": L.PROJECT_ID})
traces = len({r["trace_id"] for r in rows})
print(f"watermark {watermark} -> {new_wm}; embedded {len(out)} texts of {traces} traces "
      f"(read {t_read:.2f}s, model load {t_load:.2f}s, embed {t_embed:.2f}s, insert {t_insert:.2f}s); removed {stale} rows of deleted traces")
if len(rows) == args.max_rows:
    print("max-rows reached: run again to continue")
print(L.ch(f"SELECT kind, level, count() AS rows, uniq(trace_id) AS traces FROM {L.DB}.embeddings "
           "GROUP BY kind, level ORDER BY kind, level FORMAT PrettyCompactMonoBlock"))
