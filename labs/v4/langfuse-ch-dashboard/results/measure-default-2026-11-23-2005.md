# Panel query cost — `default` — `sql/` — 2026-11-23 — 20:05 KST, the logged end-to-end run (lab-output.md)

- ClickHouse 26.8.22.13 (shared v4 stack, Docker Desktop VM 16 GB shared with other containers, no CPU limit on the ClickHouse container)
- Range: 2026-11-09 00:00 … 2026-11-22 23:59:59 KST; project `llm-observability`, environment `lab-ch-dashboard`: 10,977 observations, 3,659 traces in range (26,074 rows in `default.events_core`)
- Median of 5 runs after one warm-up, `use_query_cache = 0`, values from `system.query_log`
- `Others`: most queries of other clients running on the server when a run started (the stack is shared; it moves the time, not the rows or bytes read)

| Panel | Median ms | Rows read | Bytes read | Peak memory | Result rows | Others |
|---|---:|---:|---:|---:|---:|---:|
| p1-traffic-kst-day | 6 | 12,319 | 0.6 MiB | 7.9 MiB | 56 | 1 |
| p2-latency-kst-day | 6 | 12,319 | 0.7 MiB | 8.0 MiB | 56 | 0 |
| p3-cost-team-krw | 22 | 12,319 | 6.8 MiB | 12.4 MiB | 42 | 1 |
| p4-failure-by-prompt | 21 | 28,517 | 1.3 MiB | 8.7 MiB | 8 | 1 |
| p5-slow-traces | 18 | 24,638 | 1.4 MiB | 7.9 MiB | 20 | 1 |
| p6-costly-traces | 28 | 12,319 | 7.7 MiB | 16.0 MiB | 20 | 1 |
| p7-score-trend | 33 | 28,517 | 1.4 MiB | 9.2 MiB | 56 | 1 |
