#!/usr/bin/env python3
"""07-bench.py — brute-force cosineDistance vs the vector similarity (HNSW) index.

On the bench server of 06-bench-up.sh (127.0.0.1:28123), with the vectors of 06-bench-embed.py:
for each size N and index quantization, one table `bench.v<N>_<quantization>`:

  1. INSERT the first N corpus vectors (RowBinary), OPTIMIZE FINAL to one part;
  2. ALTER TABLE ADD INDEX ... vector_similarity('hnsw', 'cosineDistance', 1024, <q>) and
     MATERIALIZE INDEX (mutations_sync = 2) — the wall time of this step is the build time;
  3. for 200 held-out query sentences: top-10 exact (use_skip_indexes = 0, a full scan) and
     top-10 through the index at several hnsw_candidate_list_size_for_search (ef_search) values
     (for i8 and b1 also with rescoring: 4 × 10 candidates, final distance from the f32 column);
  4. recall@10 = |index top-10 ∩ exact top-10| / 10, averaged over the queries; latency is the
     server's query_duration_ms from system.query_log (p50, p95) and the client's wall time;
     "same intent" = share of the top-10 seeded from the query's own intent (model quality).

EXPLAIN indexes = 1 is checked once per table: the index must appear for the index queries and
must not for the exact ones (the negative control).

Usage:  .venv-vector/bin/python labs/v4/langfuse-ch-vector/07-bench.py [--sizes 10000 50000 100000]
Writes  results/bench-<UTC date>.json and prints a Markdown table.
"""
import argparse
import datetime
import json
import os
import platform
import struct
import sys
import time
import uuid

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib as L

ap = argparse.ArgumentParser()
ap.add_argument("--url", default=f"http://127.0.0.1:{os.environ.get('BENCH_PORT', '28123')}")
ap.add_argument("--sizes", type=int, nargs="+", default=[10000, 50000, 100000])
ap.add_argument("--quant-at", type=int, default=100000, help="size at which i8 and b1 are also built")
ap.add_argument("--queries", type=int, default=200)
ap.add_argument("--ef", type=int, nargs="+", default=[16, 64, 256])
ap.add_argument("--k", type=int, default=10)
args = ap.parse_args()

# The bench server's default user has no password (06-bench-up.sh); do not send the shared one.
L.CH_USER = "default"
L.CH_PASSWORD = ""


def ch(q, **kw):
    return L.ch(q, url=args.url, **kw)


npz = np.load(os.path.join(L.LAB_DIR, ".run", "bench.npz"))
vecs, intents = npz["vecs"], npz["intents"]
Q, Qint = vecs[:args.queries], intents[:args.queries]
C, Cint = vecs[args.queries:], intents[args.queries:]
print(f"bench vectors: {len(C)} corpus + {len(Q)} queries, dim {vecs.shape[1]}, model {npz['model']}")
server = ch("SELECT version()").strip()
ch("CREATE DATABASE IF NOT EXISTS bench")


GROUPS = 50   # `grp` = id % 50: a filter unrelated to meaning (one app / one user), 2 % of the rows


def rowbinary(ids, ints, M):
    out = []
    for i, it, v in zip(ids, ints, M):
        b = it.encode()
        out.append(struct.pack("<IH", int(i), int(i) % GROUPS) + bytes([len(b)]) + b + b"\x80\x08"
                   + v.astype("<f4").tobytes())
    return b"".join(out)   # 0x80 0x08 = LEB128 of 1024 (array length)


def timed(sql, params, settings, tag):
    qid = f"{tag}-{uuid.uuid4().hex[:12]}"
    t = time.perf_counter()
    out = ch(sql, params=params, settings={**settings, "query_id": qid})
    return out, (time.perf_counter() - t) * 1000, qid


SQL = "SELECT id, intent FROM {t} ORDER BY cosineDistance(vec, {{q:Array(Float32)}}) LIMIT {k} FORMAT TSV"
results = []
plan = [(n, "bf16") for n in args.sizes] + [(args.quant_at, q) for q in ("f32", "i8", "b1") if args.quant_at in args.sizes]
for n, quant in plan:
    if n > len(C):
        print(f"skip N={n}: only {len(C)} corpus vectors")
        continue
    t = f"bench.v{n}_{quant}"
    ch(f"DROP TABLE IF EXISTS {t}")
    ch(f"CREATE TABLE {t} (id UInt32, grp UInt16, intent LowCardinality(String), vec Array(Float32)) ENGINE = MergeTree ORDER BY id")
    t0 = time.time()
    for s in range(0, n, 25000):
        e = min(n, s + 25000)
        ch(f"INSERT INTO {t} FORMAT RowBinary", data=rowbinary(range(s, e), Cint[s:e], C[s:e]))
    ch(f"OPTIMIZE TABLE {t} FINAL")
    t_load = time.time() - t0
    t0 = time.time()
    ch(f"ALTER TABLE {t} ADD INDEX vec_hnsw vec TYPE vector_similarity('hnsw', 'cosineDistance', 1024, '{quant}', 0, 0)")
    ch(f"ALTER TABLE {t} MATERIALIZE INDEX vec_hnsw", settings={"mutations_sync": 2})
    t_build = time.time() - t0
    part = L.ch_rows(f"SELECT count() AS parts, sum(rows) AS rows, sum(data_compressed_bytes) AS data_bytes, "
                     f"sum(secondary_indices_compressed_bytes) AS index_bytes FROM system.parts "
                     f"WHERE database = 'bench' AND table = '{t.split('.')[1]}' AND active", url=args.url)[0]
    # EXPLAIN: index used for the index query, not for the exact one (negative control)
    q0 = {"q": Q[0].tolist()}
    sql = SQL.format(t=t, k=args.k).replace(" FORMAT TSV", "")
    ex_idx = ch("EXPLAIN indexes = 1 " + sql, params=q0)
    ex_bf = ch("EXPLAIN indexes = 1 " + sql, params=q0, settings={"use_skip_indexes": 0})
    idx_used, bf_used = "vector_similarity" in ex_idx, "vector_similarity" in ex_bf
    # cold: the first index query after the build loads the index into the index cache
    _, cold_ms, _ = timed(SQL.format(t=t, k=args.k), q0, {}, "cold")
    for i in range(5):
        timed(SQL.format(t=t, k=args.k), {"q": Q[i].tolist()}, {}, "warm")
        timed(SQL.format(t=t, k=args.k), {"q": Q[i].tolist()}, {"use_skip_indexes": 0}, "warm")

    tag = f"b{uuid.uuid4().hex[:6]}"
    exact, wall = [], {"exact": []}
    for i in range(len(Q)):
        out, ms, _ = timed(SQL.format(t=t, k=args.k), {"q": Q[i].tolist()}, {"use_skip_indexes": 0}, f"{tag}-exact")
        exact.append([int(line.split("\t")[0]) for line in out.splitlines()])
        wall["exact"].append(ms)
    rows = {"exact": {"recall": 1.0, "same_intent": float(np.mean(
        [np.mean([Cint[j] == Qint[i] for j in exact[i]]) for i in range(len(Q))]))}}
    modes = [(f"ef{ef}", {"hnsw_candidate_list_size_for_search": ef}) for ef in args.ef]
    if quant in ("i8", "b1"):   # rescoring: candidates from the index, distance from the stored f32 vectors
        modes.append(("rescore4", {"vector_search_with_rescoring": 1, "vector_search_index_fetch_multiplier": 4}))
    for key, st in modes:
        rec, same, wall[key] = [], [], []
        for i in range(len(Q)):
            out, ms, _ = timed(SQL.format(t=t, k=args.k), {"q": Q[i].tolist()}, st, f"{tag}-{key}")
            got = [int(line.split("\t")[0]) for line in out.splitlines()]
            rec.append(len(set(got) & set(exact[i])) / args.k)
            same.append(np.mean([Cint[j] == Qint[i] for j in got]))
            wall[key].append(ms)
        rows[key] = {"recall": float(np.mean(rec)), "same_intent": float(np.mean(same))}
    # Filtered search on the largest bf16 table: WHERE grp = <one of 50 groups> (2 % of the rows,
    # unrelated to meaning). Rows returned and recall against the exact filtered top-k.
    filtered = {}
    if quant == "bf16" and n == max(args.sizes):
        FSQL = ("SELECT id FROM {t} WHERE grp = {{g:UInt16}} "
                "ORDER BY cosineDistance(vec, {{q:Array(Float32)}}) LIMIT {k} FORMAT TSV").format(t=t, k=args.k)
        fexact = []
        for i in range(len(Q)):
            out, _, _ = timed(FSQL, {"q": Q[i].tolist(), "g": i % GROUPS}, {"use_skip_indexes": 0}, f"{tag}-fexact")
            fexact.append([int(x) for x in out.split()])
        for key, st in [("findex", {}), ("findex_mult10", {"vector_search_index_fetch_multiplier": 10}),
                        ("findex_mult100", {"vector_search_index_fetch_multiplier": 100}),
                        ("fprefilter", {"vector_search_filter_strategy": "prefilter"})]:
            got_n, rec, wall[key] = [], [], []
            for i in range(len(Q)):
                out, ms, _ = timed(FSQL, {"q": Q[i].tolist(), "g": i % GROUPS}, st, f"{tag}-{key}")
                got = [int(x) for x in out.split()]
                got_n.append(len(got))
                rec.append(len(set(got) & set(fexact[i])) / args.k)
                wall[key].append(ms)
            filtered[key] = {"recall": float(np.mean(rec)), "same_intent": float("nan"), "mean_rows": float(np.mean(got_n))}
        rows.update(filtered)
        rows["fexact"] = {"recall": 1.0, "same_intent": float("nan"), "mean_rows": float(np.mean([len(x) for x in fexact]))}
        wall["fexact"] = []
    ch("SYSTEM FLUSH LOGS")
    lat = L.ch_rows(f"""SELECT splitByChar('-', query_id)[2] AS mode, count() AS n,
                        quantile(0.5)(query_duration_ms) AS p50, quantile(0.95)(query_duration_ms) AS p95
                        FROM system.query_log WHERE type = 'QueryFinish' AND query_id LIKE '{tag}-%'
                        GROUP BY mode""", url=args.url)
    for r in lat:
        rows[r["mode"]].update({"server_p50_ms": r["p50"], "server_p95_ms": r["p95"], "n": int(r["n"])})
    for mode, w in wall.items():
        if w:
            rows[mode]["client_p50_ms"] = round(float(np.percentile(w, 50)), 1)
    res = {"n": n, "quantization": quant, "parts": int(part["parts"]), "data_bytes": int(part["data_bytes"]),
           "index_bytes": int(part["index_bytes"]), "load_s": round(t_load, 1), "build_s": round(t_build, 1),
           "cold_first_query_ms": round(cold_ms, 1), "explain_index_used": idx_used,
           "explain_exact_uses_index": bf_used, "modes": rows}
    results.append(res)
    print(json.dumps(res, ensure_ascii=False))

meta = {"date_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "clickhouse": server, "container": "clickhouse/clickhouse-server, --memory 4g, Docker VM 12 CPUs",
        "host": f"{platform.machine()} {platform.mac_ver()[0] or platform.platform()}",
        "model": str(npz["model"]), "queries": len(Q), "k": args.k, "ef": args.ef,
        "note": "other Langfuse-lab containers were running on the same Docker VM"}
os.makedirs(os.path.join(L.LAB_DIR, "results"), exist_ok=True)
path = os.path.join(L.LAB_DIR, "results", f"bench-{meta['date_utc'][:10]}.json")
with open(path, "w") as fh:
    json.dump({"meta": meta, "results": results}, fh, ensure_ascii=False, indent=1)

print(f"\n{meta['date_utc']}, ClickHouse {server}, {len(Q)} queries, top-{args.k}\n")
print("| N | quant. | build s | index MB | mode | recall@10 | same intent | server p50 / p95 ms | client p50 ms |")
print("|---|---|---|---|---|---|---|---|---|")
for r in results:
    for mode, m in r["modes"].items():
        print(f"| {r['n']:,} | {r['quantization']} | {r['build_s']} | {r['index_bytes'] / 1e6:.0f} | {mode} | "
              f"{m['recall']:.3f} | {m['same_intent']:.3f} | {m.get('server_p50_ms', 0):.1f} / {m.get('server_p95_ms', 0):.1f} | "
              f"{m.get('client_p50_ms')} |" + (f" rows {m['mean_rows']:.1f}" if "mean_rows" in m else ""))
print(f"\nwritten {path}")
