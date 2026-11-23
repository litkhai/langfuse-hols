# Panel query cost — `lab_langfuse_ch_dashboard` — `sql-fixes/` — 2026-11-23 — 20:05 KST, the logged end-to-end run (lab-output.md)

- ClickHouse 26.8.22.13 (shared v4 stack, Docker Desktop VM 16 GB shared with other containers, no CPU limit on the ClickHouse container)
- Range: 2026-11-09 00:00 … 2026-11-22 23:59:59 KST; project `llm-observability`, environment `lab-ch-dashboard`: 10,976,421 observations, 3,658,807 traces in range (10,977,000 rows in `lab_langfuse_ch_dashboard.events_core`)
- Median of 5 runs after one warm-up, `use_query_cache = 0`, values from `system.query_log`
- `Others`: most queries of other clients running on the server when a run started (the stack is shared; it moves the time, not the rows or bytes read)

| Panel | Median ms | Rows read | Bytes read | Peak memory | Result rows | Others |
|---|---:|---:|---:|---:|---:|---:|
| p3-cost-team-krw.rollup | 3 | 58 | 0.0 MiB | 7.9 MiB | 42 | 1 |
| p3-cost-team-krw.tags | 232 | 10,977,000 | 1042.6 MiB | 17.4 MiB | 42 | 1 |
| p6-costly-traces.two-step | 235 | 12,832,943 | 841.8 MiB | 343.3 MiB | 20 | 2 |
