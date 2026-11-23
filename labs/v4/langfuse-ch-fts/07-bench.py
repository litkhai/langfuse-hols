#!/usr/bin/env python3
"""07-bench.py — LIKE / ILIKE vs hasToken vs the text index, on the lab's own ClickHouse.

The 9000 decoded rows of the copy (remote() from the stack's server) are repeated COPIES times
(default 220, about 2 million rows) into four tables that differ only in their text index:

    b_none   no index                                   — LIKE / ILIKE scan everything
    b_word   splitByNonAlpha on lower(content)          — the tokenizer Langfuse puts on events_full
    b_ng2    ngrams(2) on lower(content)
    b_cjk    asciiCJK on lower(content)                 — one token per Hangul syllable

Each repetition n gets its own trace ids and its own error codes (E1066 in copy 137 becomes
E1371066), so one search term is rare (28 rows) while the others stay as common as in the seed.
The text is templated, so it compresses far better than real model output would: compare index
sizes with the uncompressed text, not with the compressed column.

Every query runs RUNS times (default 5) after one warm-up; the numbers are the median of
system.query_log (query_duration_ms, read_rows, read_bytes, ProfileEvents SelectedMarks).
Writes .run/bench-<version>.json.

    python3 labs/v4/langfuse-ch-fts/07-bench.py            # COPIES=220 RUNS=5
    COPIES=20 python3 labs/v4/langfuse-ch-fts/07-bench.py  # quick
"""
import json
import os
import statistics
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib  # noqa: E402

DB = lablib.LAB_DB
COPIES = int(os.environ.get("COPIES", "220"))
RUNS = int(os.environ.get("RUNS", "5"))
CHUNK = 20

TABLES = {
    "b_none": None,
    "b_word": "splitByNonAlpha",
    "b_ng2": "ngrams(2)",
    "b_cjk": "asciiCJK",
}

# The rare term: error code E1066 of repetition RARE_COPY (E1066 occurs in 28 seed rows).
RARE_COPY = COPIES * 5 // 8
TERMS = ["대출", "중도상환수수료", "비밀번호 재설정", "timeout", f"E{RARE_COPY}1066"]

# use_query_condition_cache=0: with the default (1) the warm-up run records which granules matched
# a filter and later runs of the same filter skip the rest, so a plain LIKE without any index read
# 0 rows on the rare term (seen 2026-11-23 on 26.10.10.3). Off, every run does the work it describes.
QUERY_SETTINGS = {"use_query_cache": 0, "use_query_condition_cache": 0}


def esc(s):
    return s.replace("\\", "\\\\").replace("'", "\\'")


def methods(term):
    t = esc(term)
    lt = esc(term.lower())
    return [
        # (label, table, WHERE)
        ("LIKE, no index", "b_none", f"content LIKE '%{t}%'"),
        ("ILIKE, no index", "b_none", f"content ILIKE '%{t}%'"),
        ("hasToken, splitByNonAlpha", "b_word", f"hasToken(lower(content), '{lt}')" if " " not in term else None),
        ("Langfuse UI form, splitByNonAlpha", "b_word",
         f"content ILIKE '%{t}%' AND hasAllTokens(lower(content), arraySlice(arrayDistinct(tokens(lower('%{t}%'))), 1, 64))"),
        ("lower LIKE, ngrams(2)", "b_ng2", f"lower(content) LIKE '%{lt}%'"),
        ("hasAllTokens, ngrams(2)", "b_ng2", f"hasAllTokens(lower(content), '{lt}')"),
        ("hasPhrase, ngrams(2)", "b_ng2", f"hasPhrase(lower(content), '{lt}')"),
        ("hasPhrase, asciiCJK", "b_cjk", f"hasPhrase(lower(content), '{lt}')"),
    ]


def build():
    u, p = os.environ["CLICKHOUSE_USER"], os.environ["CLICKHOUSE_PASSWORD"]
    lablib.ch("FTS", f"CREATE DATABASE IF NOT EXISTS {DB}")
    lablib.ch("FTS", f"DROP TABLE IF EXISTS {DB}.src")
    lablib.ch("FTS", f"""CREATE TABLE {DB}.src ENGINE = MergeTree ORDER BY (trace_id, span_id) AS
        SELECT trace_id, span_id, name, concat(input_text, '\\n', output_text) AS content
        FROM remote('host.docker.internal:9000', {DB}.events_text, '{u}', '{p}')""")
    build_ms = {}
    for tbl, tok in TABLES.items():
        lablib.ch("FTS", f"DROP TABLE IF EXISTS {DB}.{tbl}")
        idx = f", INDEX idx lower(content) TYPE text(tokenizer = {tok})" if tok else ""
        lablib.ch("FTS", f"""CREATE TABLE {DB}.{tbl} (trace_id String, span_id String, name LowCardinality(String),
            content String CODEC(ZSTD(3)){idx}) ENGINE = MergeTree ORDER BY (trace_id, span_id)""")
        t0 = time.time()
        for start in range(0, COPIES, CHUNK):
            stop = min(start + CHUNK, COPIES)
            lablib.ch("FTS", f"""INSERT INTO {DB}.{tbl}
                SELECT concat(trace_id, '-', toString(n)), span_id, name,
                       replaceRegexpAll(content, 'E(1[0-9]{{3}})', concat('E', toString(n), '\\\\1'))
                FROM {DB}.src, (SELECT number AS n FROM numbers({start}, {stop - start})) AS c""")
        lablib.ch("FTS", f"OPTIMIZE TABLE {DB}.{tbl} FINAL", timeout=1800)
        build_ms[tbl] = round((time.time() - t0) * 1000)
        print(f"  {tbl:7} built in {build_ms[tbl] / 1000:.1f} s (inserts + OPTIMIZE FINAL)")
    return build_ms


def sizes():
    out = {}
    for r in lablib.rows("FTS", f"""SELECT table, sum(rows) AS rows, sum(data_compressed_bytes) AS compressed,
            sum(data_uncompressed_bytes) AS uncompressed, count() AS parts
            FROM system.parts WHERE database = '{DB}' AND active AND table LIKE 'b\\_%' GROUP BY table"""):
        out[r["table"]] = {"rows": int(r["rows"]), "table_compressed": int(r["compressed"]),
                           "table_uncompressed": int(r["uncompressed"]), "parts": int(r["parts"])}
    for r in lablib.rows("FTS", f"""SELECT table, data_compressed_bytes AS c, data_uncompressed_bytes AS u
            FROM system.data_skipping_indices WHERE database = '{DB}' AND table LIKE 'b\\_%'"""):
        out[r["table"]].update(index_compressed=int(r["c"]), index_uncompressed=int(r["u"]))
    for r in lablib.rows("FTS", f"""SELECT table, sum(data_compressed_bytes) AS c, sum(data_uncompressed_bytes) AS u
            FROM system.columns WHERE database = '{DB}' AND table LIKE 'b\\_%' AND name = 'content' GROUP BY table"""):
        out[r["table"]].update(content_compressed=int(r["c"]), content_uncompressed=int(r["u"]))
    return out


def run_query(sql, tag):
    res = lablib.ch("FTS", sql, settings={**QUERY_SETTINGS, "log_comment": tag}).strip()
    return int(res.split("\t")[0])


def measure(tag):
    lablib.ch("FTS", "SYSTEM FLUSH LOGS")
    rs = lablib.rows("FTS", f"""SELECT query_duration_ms AS ms, read_rows, read_bytes,
            ProfileEvents['SelectedMarks'] AS marks, ProfileEvents['SelectedRows'] AS sel_rows
            FROM system.query_log WHERE log_comment = '{tag}' AND type = 'QueryFinish' ORDER BY event_time_microseconds""")
    med = lambda k: statistics.median(int(r[k]) for r in rs)  # noqa: E731
    return {"runs": len(rs), "ms": med("ms"), "read_rows": med("read_rows"), "read_bytes": med("read_bytes"),
            "marks": med("marks"), "ms_all": [int(r["ms"]) for r in rs]}


def main():
    os.makedirs(lablib.RUN_DIR, exist_ok=True)
    version = lablib.ch("FTS", "SELECT version()").strip()
    load_start = os.getloadavg()[0]
    print(f"── lab ClickHouse {version}, {COPIES} copies of the seed, {RUNS} runs per query")
    build_ms = build()
    sz = sizes()
    marks_total = {t: int(lablib.ch("FTS", f"SELECT sum(marks) FROM system.parts WHERE database='{DB}' AND table='{t}' AND active"))
                   for t in TABLES}
    results = []
    run_id = uuid.uuid4().hex[:8]
    for term in TERMS:
        truth = int(lablib.ch("FTS", f"SELECT countIf(positionUTF8(content, '{esc(term)}') > 0) FROM {DB}.b_none"))
        print(f"  {term}  (truth {truth})")
        for label, tbl, where in methods(term):
            if where is None:
                continue
            # count() and the trace ids of the matches: what a search screen needs before it
            # fetches the rows it shows (count() alone can be answered from the index metadata).
            sql = f"SELECT count(), uniqExact(trace_id) FROM {DB}.{tbl} WHERE {where}"
            tag = f"fts-{run_id}-{len(results)}"
            try:
                run_query(sql, tag + "-warm")
                counts = {run_query(sql, tag) for _ in range(RUNS)}
            except RuntimeError as e:
                results.append({"term": term, "method": label, "table": tbl, "error": str(e).splitlines()[0][:200]})
                print(f"    {label:36} error: {str(e).splitlines()[0][:120]}")
                continue
            m = measure(tag)
            m.update(term=term, method=label, table=tbl, count=counts.pop(), truth=truth,
                     marks_total=marks_total[tbl], sql=sql)
            results.append(m)
            print(f"    {label:36} {m['count']:>8}  {m['ms']:>6.0f} ms  rows read {m['read_rows']:>9.0f}  "
                  f"marks {m['marks']:>5.0f}/{marks_total[tbl]}")
    out = {"version": version, "copies": COPIES, "runs": RUNS, "date": time.strftime("%Y-%m-%d"),
           "build_ms": build_ms, "sizes": sz, "results": results,
           "host_load_1min": {"start": round(load_start, 1), "end": round(os.getloadavg()[0], 1)},
           "host": {"max_threads": lablib.ch("FTS", "SELECT getSetting('max_threads')").strip(),
                    "memory_limit": "3 GiB (docker --memory)"}}
    path = os.path.join(lablib.RUN_DIR, f"bench-{version}.json")
    json.dump(out, open(path, "w"), ensure_ascii=False, indent=1)
    print("  sizes:")
    for t, s in sz.items():
        print(f"    {t:7} rows {s['rows']}  content {s['content_uncompressed'] / 2**20:.0f} MiB raw, "
              f"{s['content_compressed'] / 2**20:.1f} MiB compressed  index {s.get('index_compressed', 0) / 2**20:.1f} MiB")
    print(f"  host load average (1 min): {out['host_load_1min']['start']} at start, {out['host_load_1min']['end']} at end")
    print(f"✓ {os.path.relpath(path, lablib.LAB_DIR)}")


if __name__ == "__main__":
    main()
