# Panel query cost — `lab_langfuse_ch_dashboard` — `sql/` — 2026-11-23 — 19:45 KST, quiet server

- ClickHouse 26.8.22.13 (shared v4 stack, Docker Desktop VM 16 GB shared with other containers, no CPU limit on the ClickHouse container)
- Range: 2026-11-09 00:00 … 2026-11-22 23:59:59 KST; project `llm-observability`, environment `lab-ch-dashboard`: 10,976,421 observations, 3,658,807 traces in range (10,977,000 rows in `lab_langfuse_ch_dashboard.events_core`)
- Median of 5 runs after one warm-up, `use_query_cache = 0`, values from `system.query_log`
- `Others`: most queries of other clients running on the server when a run started (the stack is shared; it moves the time, not the rows or bytes read)
- Copied from the console output of that run (the file of that run was overwritten by the 20:05 run before it was renamed); start times from `system.query_log`

| Panel | Median ms | Rows read | Bytes read | Peak memory | Result rows | Others |
|---|---:|---:|---:|---:|---:|---:|
| p1-traffic-kst-day | 132 | 10,976,984 | 531.4 MiB | 14.6 MiB | 56 | 0 |
| p2-latency-kst-day | 92 | 10,976,984 | 625.6 MiB | 27.5 MiB | 56 | 0 |
| p3-cost-team-krw | 272 | 10,976,984 | 6046.8 MiB | 69.0 MiB | 42 | 0 |
| p4-failure-by-prompt | 329 | 12,399,894 | 951.2 MiB | 396.8 MiB | 8 | 0 |
| p5-slow-traces | 103 | 11,018,739 | 932.7 MiB | 10.3 MiB | 20 | 0 |
| p6-costly-traces | 529 | 10,976,984 | 6847.6 MiB | 709.9 MiB | 20 | 0 |
| p7-score-trend | 283 | 12,857,984 | 1070.7 MiB | 692.0 MiB | 56 | 0 |
