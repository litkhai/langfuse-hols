# Panel query cost — `lab_langfuse_ch_dashboard` — `sql/` — 2026-11-23 — 20:16 KST, re-run after renaming the panel files to .sql.tmpl

- ClickHouse 26.8.22.13 (shared v4 stack, Docker Desktop VM 16 GB shared with other containers, no CPU limit on the ClickHouse container)
- Range: 2026-11-09 00:00 … 2026-11-22 23:59:59 KST; project `llm-observability`, environment `lab-ch-dashboard`: 10,976,421 observations, 3,658,807 traces in range (10,977,000 rows in `lab_langfuse_ch_dashboard.events_core`)
- Median of 5 runs after one warm-up, `use_query_cache = 0`, values from `system.query_log`
- `Others`: most queries of other clients running on the server when a run started (the stack is shared; it moves the time, not the rows or bytes read)

| Panel | Median ms | Rows read | Bytes read | Peak memory | Result rows | Others |
|---|---:|---:|---:|---:|---:|---:|
| p1-traffic-kst-day | 62 | 10,976,978 | 531.4 MiB | 13.3 MiB | 56 | 0 |
| p2-latency-kst-day | 82 | 10,976,978 | 625.6 MiB | 24.8 MiB | 56 | 0 |
| p3-cost-team-krw | 206 | 10,976,978 | 6046.8 MiB | 63.8 MiB | 42 | 0 |
| p4-failure-by-prompt | 285 | 12,399,888 | 951.5 MiB | 398.6 MiB | 8 | 0 |
| p5-slow-traces | 89 | 11,018,733 | 932.7 MiB | 10.4 MiB | 20 | 0 |
| p6-costly-traces | 674 | 10,976,978 | 6847.7 MiB | 693.9 MiB | 20 | 0 |
| p7-score-trend | 644 | 12,857,978 | 1070.7 MiB | 692.4 MiB | 56 | 0 |
