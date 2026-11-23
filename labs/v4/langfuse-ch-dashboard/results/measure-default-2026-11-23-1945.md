# Panel query cost — `default` — `sql/` — 2026-11-23 — 19:45 KST, quiet server

- ClickHouse 26.8.22.13 (shared v4 stack, Docker Desktop VM 16 GB shared with other containers, no CPU limit on the ClickHouse container)
- Range: 2026-11-09 00:00 … 2026-11-22 23:59:59 KST; project `llm-observability`, environment `lab-ch-dashboard`: 10,977 observations, 3,659 traces in range
- Median of 5 runs after one warm-up, `use_query_cache = 0`, values from `system.query_log`; no other client query running
- Copied from the console output of that run (its file was overwritten by the 20:05 run before it was renamed)

| Panel | Median ms | Rows read | Bytes read | Peak memory |
|---|---:|---:|---:|---:|
| p1-traffic-kst-day | 6 | 12,361 | 0.6 MiB | 7.9 MiB |
| p2-latency-kst-day | 8 | 12,361 | 0.7 MiB | 8.0 MiB |
| p3-cost-team-krw | 8 | 12,361 | 6.9 MiB | 12.5 MiB |
| p4-failure-by-prompt | 8 | 15,242 | 1.2 MiB | 8.4 MiB |
| p5-slow-traces | 5 | 24,722 | 1.4 MiB | 7.9 MiB |
| p6-costly-traces | 6 | 12,361 | 7.8 MiB | 16.0 MiB |
| p7-score-trend | 13 | 15,242 | 1.3 MiB | 8.9 MiB |
