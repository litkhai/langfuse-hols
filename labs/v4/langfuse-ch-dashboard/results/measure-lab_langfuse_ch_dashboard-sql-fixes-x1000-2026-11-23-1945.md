# Panel query cost — `lab_langfuse_ch_dashboard` — `sql-fixes/` — 2026-11-23 — 19:45 KST, quiet server

- ClickHouse 26.8.22.13 (shared v4 stack, Docker Desktop VM 16 GB shared with other containers, no CPU limit on the ClickHouse container)
- Range: 2026-11-09 00:00 … 2026-11-22 23:59:59 KST; project `llm-observability`, environment `lab-ch-dashboard`: 10,976,421 observations, 3,658,807 traces in range (10,977,000 rows in `lab_langfuse_ch_dashboard.events_core`)
- Median of 5 runs after one warm-up, `use_query_cache = 0`, values from `system.query_log`
- `Others`: most queries of other clients running on the server when a run started (the stack is shared; it moves the time, not the rows or bytes read)
- Copied from the console output of that run (the file of that run was overwritten by the 20:05 run before it was renamed); start times from `system.query_log`

| Panel | Median ms | Rows read | Bytes read | Peak memory | Result rows | Others |
|---|---:|---:|---:|---:|---:|---:|
| p3-cost-team-krw.rollup | 4 | 58 | 0.0 MiB | 7.9 MiB | 42 | 0 |
| p3-cost-team-krw.tags | 90 | 10,976,984 | 1042.6 MiB | 17.4 MiB | 42 | 0 |
| p6-costly-traces.two-step | 213 | 12,832,099 | 841.7 MiB | 345.3 MiB | 20 | 0 |
