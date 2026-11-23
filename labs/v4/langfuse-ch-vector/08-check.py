#!/usr/bin/env python3
"""08-check.py — what the lab claims, checked against ClickHouse. Non-zero exit on any failure.

--fault swaps the expected intent of the similar-case search (app errors ↔ currency exchange):
the two search checks must then fail, which shows they can fail.

Usage:  .venv-vector/bin/python labs/v4/langfuse-ch-vector/08-check.py [--fault]
"""
import argparse
import glob
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib as L

ap = argparse.ArgumentParser()
ap.add_argument("--fault", action="store_true")
args = ap.parse_args()

results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""))


P = {"tag": L.LAB_TAG, "project": L.PROJECT_ID}

# 1. every root input and output of the lab's traces is embedded, once
src = int(L.ch("""SELECT countIf(input NOT IN ('', 'null', '{}')) + countIf(output NOT IN ('', 'null', '{}'))
FROM (SELECT input, output, is_deleted FROM default.events_full
      WHERE project_id = {project:String} AND has(tags, {tag:String}) AND parent_span_id = ''
      ORDER BY span_id, event_ts DESC LIMIT 1 BY span_id) WHERE is_deleted = 0""", params=P).strip())
emb = L.ch_rows(f"SELECT count() AS n, uniqExact(span_id, kind) AS u FROM {L.DB}.embeddings "
                "WHERE project_id = {project:String}", params=P)[0]
check("every root input/output of the lab's traces is embedded exactly once",
      int(emb["n"]) == src and int(emb["u"]) == src, f"events_full {src}, embeddings {emb['n']}, distinct {emb['u']}")

# 2. a second pipeline run adds nothing
out = subprocess.run([sys.executable, os.path.join(L.LAB_DIR, "03-embed.py")], capture_output=True, text=True).stdout
check("re-running 03-embed.py embeds 0 texts", "embedded 0 texts" in out, out.splitlines()[0] if out else "no output")

# 3. vectors: 1024 dimensions, unit length
v = L.ch_rows(f"SELECT min(length(vec)) AS dmin, max(length(vec)) AS dmax, round(min(L2Norm(vec)), 4) AS nmin, "
              f"round(max(L2Norm(vec)), 4) AS nmax FROM {L.DB}.embeddings")[0]
check("vectors have 1024 dimensions and L2 norm 1 (±0.001)",
      v["dmin"] == v["dmax"] == 1024 and abs(v["nmin"] - 1) < 1e-3 and abs(v["nmax"] - 1) < 1e-3, json.dumps(v))

# 4. similar-case search: the failing trace's neighbours are app errors; an exchange question's are not
truth_sql = ("SELECT trace_id, metadata_values[indexOf(metadata_names, 'seed_intent')] AS intent FROM default.events_full "
             "WHERE has(tags, {tag:String}) AND parent_span_id = '' LIMIT 1 BY trace_id")
truth = {r["trace_id"]: r["intent"] for r in L.ch_rows(truth_sql, params=P)}
failing_path = os.path.join(L.LAB_DIR, ".run", "failing_trace_id")
failing = open(failing_path).read().strip() if os.path.exists(failing_path) else ""
want, other = ("fx", "app_error") if args.fault else ("app_error", "fx")


def neighbours(vec_sql, params):
    return L.ch_rows(f"WITH ({vec_sql}) AS q SELECT trace_id FROM {L.DB}.embeddings WHERE kind = 'input' "
                     "AND trace_id != {self:String} ORDER BY cosineDistance(vec, q) LIMIT 10", params=params,
                     settings={"use_skip_indexes": 0})


nb = neighbours(f"SELECT vec FROM {L.DB}.embeddings WHERE kind = 'input' AND trace_id = {{self:String}}",
                {"self": failing}) if failing else []
hit = sum(truth.get(r["trace_id"]) == want for r in nb)
check(f"failing trace: at least 8 of its 10 nearest traces are '{want}'", hit >= 8, f"{hit}/10, trace {failing or 'missing'}")

qv = L.embed(["유로로 환전하면 수수료가 얼마나 나와요?"])[0].tolist()
nb2 = L.ch_rows(f"SELECT trace_id FROM {L.DB}.embeddings WHERE kind = 'input' "
                "ORDER BY cosineDistance(vec, {q:Array(Float32)}) LIMIT 10", params={"q": qv},
                settings={"use_skip_indexes": 0})
miss = sum(truth.get(r["trace_id"]) == want for r in nb2)
check(f"negative control: an exchange question has no '{want}' trace among its 10 nearest", miss == 0, f"{miss}/10")

# 4b. the post-filtering trap of 04-similar.py: through the index, WHERE kind = 'input' returns
#     fewer than 10 rows; with pre-filtering it returns 10
idx_sql = (f"SELECT trace_id FROM {L.DB}.embeddings WHERE kind = 'input' "
           "ORDER BY cosineDistance(vec, {q:Array(Float32)}) LIMIT 10")
n_post = len(L.ch_rows(idx_sql, params={"q": qv}))
n_pre = len(L.ch_rows(idx_sql, params={"q": qv}, settings={"vector_search_filter_strategy": "prefilter"}))
check("index + WHERE kind = 'input': post-filtering returns < 10 rows, pre-filtering 10",
      n_post < 10 and n_pre == 10, f"post {n_post}, pre {n_pre}")

# 5. topics: the latest run agrees with the seed intents
run = L.ch("SELECT max(run_id) FROM {db}.topics".format(db=L.DB)).strip()
pairs = L.ch_rows(f"SELECT trace_id, topic FROM {L.DB}.topics WHERE run_id = {{r:String}}", params={"r": run})
if pairs:
    from sklearn.metrics import adjusted_rand_score
    ari = adjusted_rand_score([truth.get(p["trace_id"], "?") for p in pairs], [p["topic"] for p in pairs])
    check("topics of the latest 05-topics.py run: adjusted Rand index >= 0.7", ari >= 0.7, f"run {run}, ARI {ari:.3f}")
else:
    check("topics of the latest 05-topics.py run exist", False, "run 05-topics.py")

# 6. benchmark (if run): the index is used for the index queries only, and recall at the default ef
files = sorted(glob.glob(os.path.join(L.LAB_DIR, "results", "bench-*.json")))
if files:
    b = json.load(open(files[-1]))["results"]
    check("bench: EXPLAIN shows the vector index for index queries, not for exact ones",
          all(r["explain_index_used"] and not r["explain_exact_uses_index"] for r in b), os.path.basename(files[-1]))
    bf = [r for r in b if r["quantization"] == "bf16"]
    worst = min(r["modes"]["ef256"]["recall"] for r in bf)
    check("bench: recall@10 >= 0.95 with bf16 at the default ef_search 256, every size", worst >= 0.95, f"min {worst:.3f}")
    check("bench: every table was searched as one part", all(r["parts"] == 1 for r in b))
else:
    print("skip  bench checks: no results/bench-*.json (run 06-bench-up.sh, 06-bench-embed.py, 07-bench.py)")

n_fail = results.count(False)
print(f"\n{len(results) - n_fail} passed, {n_fail} failed")
sys.exit(1 if n_fail else 0)
