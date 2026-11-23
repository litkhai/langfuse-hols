# Panel query cost — `lab_langfuse_ch_dashboard` — `sql/` — 2026-11-23 — 20:05 KST, the logged end-to-end run (lab-output.md)

- ClickHouse 26.8.22.13 (shared v4 stack, Docker Desktop VM 16 GB shared with other containers, no CPU limit on the ClickHouse container)
- Range: 2026-11-09 00:00 … 2026-11-22 23:59:59 KST; project `llm-observability`, environment `lab-ch-dashboard`: 10,976,421 observations, 3,658,807 traces in range (10,977,000 rows in `lab_langfuse_ch_dashboard.events_core`)
- Median of 5 runs after one warm-up, `use_query_cache = 0`, values from `system.query_log`
- `Others`: most queries of other clients running on the server when a run started (the stack is shared; it moves the time, not the rows or bytes read)

| Panel | Median ms | Rows read | Bytes read | Peak memory | Result rows | Others |
|---|---:|---:|---:|---:|---:|---:|
| p1-traffic-kst-day | 126 | 10,977,000 | 531.4 MiB | 14.6 MiB | 56 | 1 |
| p2-latency-kst-day | 347 | 10,977,000 | 625.6 MiB | 31.3 MiB | 56 | 1 |
| p3-cost-team-krw | 468 | 10,977,000 | 6046.8 MiB | 61.5 MiB | 42 | 1 |
| p4-failure-by-prompt | 566 | 12,399,910 | 951.2 MiB | 402.8 MiB | 8 | 0 |
| p5-slow-traces | 183 | 11,018,755 | 932.7 MiB | 10.4 MiB | 20 | 0 |
| p6-costly-traces | 1479 | 10,977,000 | 6847.6 MiB | 710.8 MiB | 20 | 1 |
| p7-score-trend | 1347 | 12,858,000 | 1070.7 MiB | 692.6 MiB | 56 | 0 |
