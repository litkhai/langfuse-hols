#!/usr/bin/env python3
"""04 — a scaled copy of this lab's traces in lab_langfuse_ch_dashboard, to measure the panels at size.

The copy has the same DDL as Langfuse's tables (CREATE TABLE … AS default.events_core / default.scores:
engine, sort key, partitioning, skip indexes and MATERIALIZED columns included) and holds the seeded
rows of environment lab-ch-dashboard N times. Copy k gets new trace/span/score ids (the first four
hex digits replaced by k) and its own offset of up to ±30 minutes per trace, so the copies do not
collapse into one under ReplacingMergeTree and do not stack on the same minute. Langfuse's own tables
are only read.

  python 04-scale-copy.py [--copies 300]
"""

from __future__ import annotations

import argparse
import sys
import time

from lablib import ENVIRONMENT, LAB_DB, PROJECT, ch

SHIFT = "toIntervalSecond(toInt64(cityHash64(k, trace_id) % 3600) - 1800)"


def rid(col: str) -> str:
    return f"if({col} = '', '', concat(leftPad(lower(hex(toUInt16(k))), 4, '0'), substring({col}, 5)))"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--copies", type=int, default=300)
    ap.add_argument("--chunk", type=int, default=25)
    a = ap.parse_args()
    ch(f"CREATE DATABASE IF NOT EXISTS {LAB_DB}")
    ch(f"CREATE TABLE IF NOT EXISTS {LAB_DB}.events_core AS default.events_core")
    ch(f"CREATE TABLE IF NOT EXISTS {LAB_DB}.scores AS default.scores")
    ch(f"TRUNCATE TABLE {LAB_DB}.events_core")
    ch(f"TRUNCATE TABLE {LAB_DB}.scores")
    src = f"project_id = '{PROJECT}' AND environment = '{ENVIRONMENT}'"
    t0 = time.time()
    for lo in range(0, a.copies, a.chunk):
        hi = min(a.copies, lo + a.chunk)
        ch(f"""INSERT INTO {LAB_DB}.events_core
SELECT * REPLACE ({rid('trace_id')} AS trace_id, {rid('span_id')} AS span_id,
                  {rid('parent_span_id')} AS parent_span_id,
                  start_time + {SHIFT} AS start_time,
                  if(end_time IS NULL, NULL, end_time + {SHIFT}) AS end_time,
                  if(completion_start_time IS NULL, NULL, completion_start_time + {SHIFT}) AS completion_start_time)
FROM default.events_core ARRAY JOIN range({lo}, {hi}) AS k
WHERE {src}""", {"max_insert_threads": "2", "max_threads": "4"})
        ch(f"""INSERT INTO {LAB_DB}.scores
SELECT * REPLACE ({rid('id')} AS id, {rid('assumeNotNull(trace_id)')} AS trace_id,
                  timestamp + toIntervalSecond(toInt64(cityHash64(k, trace_id) % 3600) - 1800) AS timestamp)
FROM default.scores ARRAY JOIN range({lo}, {hi}) AS k
WHERE {src}""")
        print(f"  copies {lo}…{hi - 1} done ({time.time() - t0:.0f} s)", flush=True)
    ch(f"OPTIMIZE TABLE {LAB_DB}.events_core FINAL")
    ch(f"OPTIMIZE TABLE {LAB_DB}.scores FINAL")
    r = ch(f"SELECT count() AS rows, uniqExact(trace_id) AS traces FROM {LAB_DB}.events_core")
    d = ch(f"SELECT formatReadableSize(sum(data_compressed_bytes)) AS on_disk FROM system.parts "
           f"WHERE database = '{LAB_DB}' AND table = 'events_core' AND active")
    r[0]["on_disk"] = d[0]["on_disk"]
    s = ch(f"SELECT count() AS n FROM {LAB_DB}.scores")[0]["n"]
    print(f"✓ {LAB_DB}.events_core: {r[0]['rows']} rows, {r[0]['traces']} traces, {r[0]['on_disk']} on disk; "
          f"scores: {s} ({time.time() - t0:.0f} s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
