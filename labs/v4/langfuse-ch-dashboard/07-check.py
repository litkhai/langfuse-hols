#!/usr/bin/env python3
"""07 — checks: the seed landed, every panel answers through Grafana, the fixes return the same rows.

1. ClickHouse holds the seeded window: traces, generations with cost, both score names, and no row twice
   (the panels count rows without FINAL).
2. Each of the 7 panels runs through Grafana's /api/ds/query (the datasource plugin expands
   $__timeFilter itself; dashboard variables are substituted here, as the browser would) and returns
   rows. Negative control: the same call with an unknown environment returns none.
3. The signal the dashboard is for: prompt ch-dash-loan-advisor v3 fails at least twice as often as v2.
4. KST vs UTC: the KST day 2026-11-09 and the UTC day 2026-11-09 hold different trace counts
   (Langfuse's widgets bucket by UTC day; see the README).
5. On the scaled copy (if present): fixes in sql-fixes/ return the same rows as the panels they replace.

--fault swaps the expectation of check 3 (v2 must fail twice as often as v3) and must make the run fail.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path

import httpx

from lablib import ENVIRONMENT, LAB_DB, LAB_DIR, PROJECT, ch

spec = importlib.util.spec_from_file_location("measure", LAB_DIR / "05-measure.py")
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)

G = f"http://127.0.0.1:{os.environ.get('GRAFANA_PORT', '58300')}"
PW = (LAB_DIR / ".run" / "grafana-admin").read_text().strip()
F, T = 1794150000, 1795359599          # 2026-11-09 00:00:00 … 2026-11-22 23:59:59 KST
fails = 0


def check(ok: bool, msg: str) -> None:
    global fails
    print(("✓ " if ok else "✗ ") + msg)
    fails += not ok


def grafana(sql: str, env: str = ENVIRONMENT) -> int:
    for k, v in {"${db}": "default", "${project}": PROJECT, "${environment:singlequote}": f"'{env}'",
                 "${krw_per_usd}": "1400"}.items():
        sql = sql.replace(k, v)
    body = {"queries": [{"refId": "A", "datasource": {"uid": "langfuse-ch"}, "rawSql": sql, "format": 1,
                         "queryType": "sql", "editorType": "sql"}],
            "from": str(F * 1000), "to": str(T * 1000)}
    r = httpx.post(f"{G}/api/ds/query", json=body, auth=("admin", PW), timeout=60)
    r.raise_for_status()
    res = r.json()["results"]["A"]
    if res.get("error"):
        raise RuntimeError(res["error"])
    frames = res.get("frames") or []
    vals = frames[0]["data"]["values"] if frames else []
    return len(vals[0]) if vals else 0


w = f"project_id = '{PROJECT}' AND environment = '{ENVIRONMENT}' AND start_time >= toDateTime({F}) AND start_time <= toDateTime({T})"
s = ch(f"""SELECT uniqExactIf(trace_id, parent_span_id = '') AS traces, countIf(type = 'GENERATION') AS gens,
  sumIf(calculated_total_cost, type = 'GENERATION') AS usd FROM default.events_core WHERE {w}""")[0]
check(int(s["traces"]) > 3000 and float(s["usd"]) > 0, f"seed: {s['traces']} traces, {s['gens']} generations, ${float(s['usd']):.2f}")
d = ch(f"""SELECT (SELECT count() - uniqExact(span_id) FROM default.events_core WHERE {w}) AS ev,
  (SELECT count() - uniqExact(id) FROM default.scores WHERE project_id = '{PROJECT}' AND environment = '{ENVIRONMENT}') AS sc""")[0]
check(int(d["ev"]) == 0 and int(d["sc"]) == 0, f"no duplicate rows (panels use no FINAL): observations {d['ev']}, scores {d['sc']}")
sc = {r["name"]: int(r["n"]) for r in ch(f"SELECT name, count() AS n FROM default.scores WHERE project_id = '{PROJECT}' "
                                         f"AND environment = '{ENVIRONMENT}' GROUP BY name")}
check(sc.get("user-feedback", 0) > 0 and sc.get("judge-faithfulness", 0) > 0, f"scores: {sc}")

for p in sorted((LAB_DIR / "sql").glob("*.sql")):
    n = grafana(p.read_text())
    neg = grafana(p.read_text(), env="no-such-environment")
    check(n > 0 and neg == 0, f"Grafana {p.stem}: {n} rows (unknown environment: {neg})")

rows = ch(measure.expand((LAB_DIR / "sql" / "p4-failure-by-prompt.sql").read_text(), "default", F, T, "1400"))
loan = {int(r["version"]): float(r["failure_pct"]) for r in rows if r["prompt"] == "ch-dash-loan-advisor"}
hi, lo = (2, 3) if "--fault" in sys.argv else (3, 2)
check(loan.get(hi, 0) >= 2 * loan.get(lo, 99), f"loan-advisor failure %: v{hi} at least twice v{lo} {loan}")

k = ch(f"""SELECT countIf(toDate(start_time, 'Asia/Seoul') = '2026-11-09') AS kst,
  countIf(toDate(start_time) = '2026-11-09') AS utc FROM default.events_core
WHERE project_id = '{PROJECT}' AND environment = '{ENVIRONMENT}' AND parent_span_id = ''""")[0]
check(int(k["kst"]) != int(k["utc"]), f"2026-11-09 traces: KST day {k['kst']}, UTC day {k['utc']}")

if ch(f"SELECT count() AS n FROM system.tables WHERE database = '{LAB_DB}' AND name = 'cost_team_day'")[0]["n"] != "0":
    for fix, orig in [("p3-cost-team-krw.tags", "p3-cost-team-krw"), ("p3-cost-team-krw.rollup", "p3-cost-team-krw"),
                      ("p6-costly-traces.two-step", "p6-costly-traces")]:
        a = ch(measure.expand((LAB_DIR / "sql" / f"{orig}.sql").read_text(), LAB_DB, F, T, "1400"))
        b = ch(measure.expand((LAB_DIR / "sql-fixes" / f"{fix}.sql").read_text(), LAB_DB, F, T, "1400"))
        check(len(a) > 0 and json.dumps(a) == json.dumps(b), f"{fix} = {orig} on {LAB_DB} ({len(a)} rows)")
else:
    print(f"- {LAB_DB}.cost_team_day not there: run 04-scale-copy.py and 06-rollup.sql for check 5")

print("✓ all checks passed" if not fails else f"✗ {fails} check(s) failed")
sys.exit(1 if fails else 0)
