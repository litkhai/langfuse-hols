#!/usr/bin/env python3
"""05 — query cost of every panel: rows and bytes read, duration, peak memory (system.query_log).

Expands each sql/*.sql.tmpl (SQL with Grafana macros, so not plain .sql) the way grafana-clickhouse-datasource 4.23.5 does ($__timeFilter(c) →
`c >= toDateTime(<from>) AND c <= toDateTime(<to>)`, ${var} → its value; checked against the
queries Grafana sent, which query_log records with `grafana_panel:<id>` in http_user_agent), runs it
--runs times with the query cache off, and reports the median. The first run is a warm-up and not
counted. Writes results/measure-<db>-<date>.md.

  python 05-measure.py [--db default|lab_langfuse_ch_dashboard] [--runs 5] [--from 2026-11-09 --to 2026-11-22]
"""

from __future__ import annotations

import argparse
import re
import statistics
import sys
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from lablib import ENVIRONMENT, LAB_DIR, PROJECT, ch

KST = timezone(timedelta(hours=9))


def expand(sql: str, db: str, t_from: int, t_to: int, krw: str) -> str:
    sql = re.sub(r"\$__timeFilter\(([^)]+)\)",
                 lambda m: f"{m.group(1)} >= toDateTime({t_from}) AND {m.group(1)} <= toDateTime({t_to})", sql)
    for k, v in {"${db}": db, "${project}": PROJECT, "${environment:singlequote}": f"'{ENVIRONMENT}'",
                 "${krw_per_usd}": krw}.items():
        sql = sql.replace(k, v)
    return sql


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="default")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--from", dest="d_from", default="2026-11-09")
    ap.add_argument("--to", dest="d_to", default="2026-11-22")
    ap.add_argument("--krw", default="1400")
    ap.add_argument("--only", help="regex on the panel file name")
    ap.add_argument("--sql-dir", default="sql")
    ap.add_argument("--label", default="", help="appended to the result file name, e.g. x300")
    a = ap.parse_args()
    f = datetime.combine(date.fromisoformat(a.d_from), datetime.min.time(), KST)
    t = datetime.combine(date.fromisoformat(a.d_to), datetime.max.time().replace(microsecond=0), KST)
    t_from, t_to = int(f.timestamp()), int(t.timestamp())

    ver = ch("SELECT version() AS v")[0]["v"]
    size = ch(f"SELECT count() AS rows, uniqExact(trace_id) AS traces FROM {a.db}.events_core "
              f"WHERE project_id = '{PROJECT}' AND environment = '{ENVIRONMENT}' "
              f"AND start_time >= toDateTime({t_from}) AND start_time <= toDateTime({t_to})")[0]
    total = ch(f"SELECT count() AS rows FROM {a.db}.events_core")[0]["rows"]
    files = sorted(p for p in (LAB_DIR / a.sql_dir).glob("*.sql.tmpl") if not a.only or re.search(a.only, p.name))
    rows = []
    for p in files:
        q = expand(p.read_text(), a.db, t_from, t_to, a.krw)
        name = p.name.removesuffix(".sql.tmpl")
        tag = f"chd-{name}-{uuid.uuid4().hex[:8]}"
        busy = 0
        for i in range(a.runs + 1):
            busy = max(busy, int(ch("SELECT count() AS n FROM system.processes WHERE query_id != queryID()")[0]["n"]))
            ch(q, {"log_comment": f"{tag}-{i}", "use_query_cache": "0"})
        ch("SYSTEM FLUSH LOGS")
        log = ch(f"""SELECT log_comment, query_duration_ms AS ms, read_rows, read_bytes, memory_usage, result_rows
FROM system.query_log WHERE type = 'QueryFinish' AND log_comment LIKE '{tag}-%'
  AND log_comment != '{tag}-0' AND event_date >= yesterday()""")
        med = lambda k: statistics.median(int(r[k]) for r in log)
        rows.append(dict(panel=name, ms=med("ms"), read_rows=med("read_rows"), read_bytes=med("read_bytes"),
                         mem=med("memory_usage"), result=int(log[0]["result_rows"]), n=len(log), busy=busy))
        print(f"  {name:28s} {rows[-1]['ms']:>7.0f} ms  {rows[-1]['read_rows']:>11,.0f} rows  "
              f"{rows[-1]['read_bytes'] / 2**20:>8.1f} MiB  mem {rows[-1]['mem'] / 2**20:>7.1f} MiB  "
              f"(other queries running: up to {busy})", flush=True)

    today = datetime.now(KST).date().isoformat()
    suffix = ("" if a.sql_dir == "sql" else f"-{Path(a.sql_dir).name}") + (f"-{a.label}" if a.label else "")
    out = LAB_DIR / "results" / f"measure-{a.db}{suffix}-{today}.md"
    out.parent.mkdir(exist_ok=True)
    lines = [f"# Panel query cost — `{a.db}` — `{a.sql_dir}/` — {today}", "",
             f"- ClickHouse {ver} (shared v4 stack, Docker Desktop VM 16 GB shared with other containers, "
             f"no CPU limit on the ClickHouse container)",
             f"- Range: {a.d_from} 00:00 … {a.d_to} 23:59:59 KST; project `{PROJECT}`, environment `{ENVIRONMENT}`: "
             f"{int(size['rows']):,} observations, {int(size['traces']):,} traces in range "
             f"({int(total):,} rows in `{a.db}.events_core`)",
             f"- Median of {a.runs} runs after one warm-up, `use_query_cache = 0`, values from `system.query_log`",
             "- `Others`: most queries of other clients running on the server when a run started "
             "(the stack is shared; it moves the time, not the rows or bytes read)", "",
             "| Panel | Median ms | Rows read | Bytes read | Peak memory | Result rows | Others |",
             "|---|---:|---:|---:|---:|---:|---:|"]
    for r in rows:
        lines.append(f"| {r['panel']} | {r['ms']:.0f} | {r['read_rows']:,.0f} | {r['read_bytes'] / 2**20:.1f} MiB | "
                     f"{r['mem'] / 2**20:.1f} MiB | {r['result']} | {r['busy']} |")
    out.write_text("\n".join(lines) + "\n")
    print(f"✓ wrote {out.relative_to(LAB_DIR)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
