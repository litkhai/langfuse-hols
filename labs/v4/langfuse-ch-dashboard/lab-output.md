# lab-output — langfuse-ch-dashboard, end-to-end run of 2026-11-23

Langfuse v4.56.0 / SDK 4.17.0 / CH 26.8.22.13 (shared v4 stack, `events_only`), Grafana OSS 13.2.6 + grafana-clickhouse-datasource 4.23.5, Docker 29.9.3, Compose v5.7.0, Python 3.12.14, Node 26.10.0.
Before the run, the traces of an earlier run were deleted with `99-down.sh --traces` and the run waited until `events_core`, `events_full` and `scores` held 0 rows of environment `lab-ch-dashboard`. The `$PY` path is shortened; `05-measure.py` wrote the files now named `results/*-2005.md`.

```text
# run started 2026-11-23 19:55:56 KST

$ $PY 01-prompts.py
✓ ch-dash-loan-advisor: 3 versions
✓ ch-dash-card-faq: 2 versions
✓ ch-dash-doc-summary: 1 versions
✓ ch-dash-policy-search: 2 versions

$ $PY 02-seed.py --end 2026-11-22
  2026-11-09  … 329 traces so far
  2026-11-10  … 640 traces so far
  2026-11-11  … 991 traces so far
  2026-11-12  … 1277 traces so far
  2026-11-13  … 1567 traces so far
  2026-11-14 (weekend) … 1676 traces so far
  2026-11-15 (weekend) … 1797 traces so far
  2026-11-16  … 2107 traces so far
  2026-11-17  … 2434 traces so far
  2026-11-18  … 2727 traces so far
  2026-11-19  … 3081 traces so far
  2026-11-20  … 3407 traces so far
  2026-11-21 (weekend) … 3526 traces so far
  2026-11-22 (weekend) … 3659 traces so far
✓ spans sent: 3659 traces (97 failed), window 2026-11-09 … 2026-11-22 KST
✓ scores sent: 1881/1881
  in ClickHouse: 3659/3659 traces
✓ all traces in ClickHouse

$ ./03-grafana-up.sh
✓ wrote grafana/dashboards/langfuse-kr.json (7 panels)
 Container lf-ch-dashboard-grafana-1 Creating 
 Container lf-ch-dashboard-grafana-1 Created 
 Container lf-ch-dashboard-grafana-1 Starting 
 Container lf-ch-dashboard-grafana-1 Started 
✓ Grafana 13.2.6, grafana-clickhouse-datasource 4.23.5, ClickHouse 26.8.22.13
  dashboard: http://127.0.0.1:58300/d/langfuse-kr  (admin password: .run/grafana-admin)

$ $PY 04-scale-copy.py --copies 1000
  copies 0…24 done (10 s)
  copies 25…49 done (14 s)
  copies 50…74 done (18 s)
  copies 75…99 done (22 s)
  copies 100…124 done (26 s)
  copies 125…149 done (31 s)
  copies 150…174 done (36 s)
  copies 175…199 done (41 s)
  copies 200…224 done (45 s)
  copies 225…249 done (48 s)
  copies 250…274 done (51 s)
  copies 275…299 done (54 s)
  copies 300…324 done (59 s)
  copies 325…349 done (64 s)
  copies 350…374 done (68 s)
  copies 375…399 done (72 s)
  copies 400…424 done (82 s)
  copies 425…449 done (112 s)
  copies 450…474 done (128 s)
  copies 475…499 done (133 s)
  copies 500…524 done (140 s)
  copies 525…549 done (146 s)
  copies 550…574 done (154 s)
  copies 575…599 done (162 s)
  copies 600…624 done (174 s)
  copies 625…649 done (182 s)
  copies 650…674 done (192 s)
  copies 675…699 done (207 s)
  copies 700…724 done (224 s)
  copies 725…749 done (236 s)
  copies 750…774 done (250 s)
  copies 775…799 done (269 s)
  copies 800…824 done (284 s)
  copies 825…849 done (295 s)
  copies 850…874 done (307 s)
  copies 875…899 done (324 s)
  copies 900…924 done (336 s)
  copies 925…949 done (380 s)
  copies 950…974 done (393 s)
  copies 975…999 done (424 s)
✓ lab_langfuse_ch_dashboard.events_core: 10977000 rows, 3659000 traces, 1.01 GiB on disk; scores: 1881000 (494 s)

$ clickhouse-client --multiquery < 06-rollup.sql
✓ rollup built

$ $PY 05-measure.py --db default
  p1-traffic-kst-day                 6 ms       12,319 rows       0.6 MiB  mem     7.9 MiB  (other queries running: up to 1)
  p2-latency-kst-day                 6 ms       12,319 rows       0.7 MiB  mem     8.0 MiB  (other queries running: up to 0)
  p3-cost-team-krw                  22 ms       12,319 rows       6.8 MiB  mem    12.4 MiB  (other queries running: up to 1)
  p4-failure-by-prompt              21 ms       28,517 rows       1.3 MiB  mem     8.7 MiB  (other queries running: up to 1)
  p5-slow-traces                    18 ms       24,638 rows       1.4 MiB  mem     7.9 MiB  (other queries running: up to 1)
  p6-costly-traces                  28 ms       12,319 rows       7.7 MiB  mem    16.0 MiB  (other queries running: up to 1)
  p7-score-trend                    33 ms       28,517 rows       1.4 MiB  mem     9.2 MiB  (other queries running: up to 1)
✓ wrote results/measure-default-2026-11-23.md

$ $PY 05-measure.py --db lab_langfuse_ch_dashboard --label x1000
  p1-traffic-kst-day               126 ms   10,977,000 rows     531.4 MiB  mem    14.6 MiB  (other queries running: up to 1)
  p2-latency-kst-day               347 ms   10,977,000 rows     625.6 MiB  mem    31.3 MiB  (other queries running: up to 1)
  p3-cost-team-krw                 468 ms   10,977,000 rows    6046.8 MiB  mem    61.5 MiB  (other queries running: up to 1)
  p4-failure-by-prompt             566 ms   12,399,910 rows     951.2 MiB  mem   402.8 MiB  (other queries running: up to 0)
  p5-slow-traces                   183 ms   11,018,755 rows     932.7 MiB  mem    10.4 MiB  (other queries running: up to 0)
  p6-costly-traces                1479 ms   10,977,000 rows    6847.6 MiB  mem   710.8 MiB  (other queries running: up to 1)
  p7-score-trend                  1347 ms   12,858,000 rows    1070.7 MiB  mem   692.6 MiB  (other queries running: up to 0)
✓ wrote results/measure-lab_langfuse_ch_dashboard-x1000-2026-11-23.md

$ $PY 05-measure.py --db lab_langfuse_ch_dashboard --sql-dir sql-fixes --label x1000
  p3-cost-team-krw.rollup            3 ms           58 rows       0.0 MiB  mem     7.9 MiB  (other queries running: up to 1)
  p3-cost-team-krw.tags            232 ms   10,977,000 rows    1042.6 MiB  mem    17.4 MiB  (other queries running: up to 1)
  p6-costly-traces.two-step        235 ms   12,832,943 rows     841.8 MiB  mem   343.3 MiB  (other queries running: up to 2)
✓ wrote results/measure-lab_langfuse_ch_dashboard-sql-fixes-x1000-2026-11-23.md

$ $PY 07-check.py
✓ seed: 3659 traces, 3659 generations, $23.41
✓ no duplicate rows (panels use no FINAL): observations 0, scores 0
✓ scores: {'judge-faithfulness': 1282, 'user-feedback': 599}
✓ Grafana p1-traffic-kst-day: 56 rows (unknown environment: 0)
✓ Grafana p2-latency-kst-day: 56 rows (unknown environment: 0)
✓ Grafana p3-cost-team-krw: 42 rows (unknown environment: 0)
✓ Grafana p4-failure-by-prompt: 8 rows (unknown environment: 0)
✓ Grafana p5-slow-traces: 20 rows (unknown environment: 0)
✓ Grafana p6-costly-traces: 20 rows (unknown environment: 0)
✓ Grafana p7-score-trend: 56 rows (unknown environment: 0)
✓ loan-advisor failure %: v3 at least twice v2 {1: 1.47, 2: 1.66, 3: 7.14}
✓ 2026-11-09 traces: KST day 329, UTC day 325
✓ p3-cost-team-krw.tags = p3-cost-team-krw on lab_langfuse_ch_dashboard (42 rows)
✓ p3-cost-team-krw.rollup = p3-cost-team-krw on lab_langfuse_ch_dashboard (42 rows)
✓ p6-costly-traces.two-step = p6-costly-traces on lab_langfuse_ch_dashboard (20 rows)
✓ all checks passed

$ $PY 07-check.py --fault   (must fail)
✓ seed: 3659 traces, 3659 generations, $23.41
✓ no duplicate rows (panels use no FINAL): observations 0, scores 0
✓ scores: {'judge-faithfulness': 1282, 'user-feedback': 599}
✓ Grafana p1-traffic-kst-day: 56 rows (unknown environment: 0)
✓ Grafana p2-latency-kst-day: 56 rows (unknown environment: 0)
✓ Grafana p3-cost-team-krw: 42 rows (unknown environment: 0)
✓ Grafana p4-failure-by-prompt: 8 rows (unknown environment: 0)
✓ Grafana p5-slow-traces: 20 rows (unknown environment: 0)
✓ Grafana p6-costly-traces: 20 rows (unknown environment: 0)
✓ Grafana p7-score-trend: 56 rows (unknown environment: 0)
✗ loan-advisor failure %: v2 at least twice v3 {1: 1.47, 2: 1.66, 3: 7.14}
✓ 2026-11-09 traces: KST day 329, UTC day 325
✓ p3-cost-team-krw.tags = p3-cost-team-krw on lab_langfuse_ch_dashboard (42 rows)
✓ p3-cost-team-krw.rollup = p3-cost-team-krw on lab_langfuse_ch_dashboard (42 rows)
✓ p6-costly-traces.two-step = p6-costly-traces on lab_langfuse_ch_dashboard (20 rows)
✗ 1 check(s) failed
✓ --fault failed as it must (exit 1)

$ node 08-captures.mjs
captures/langfuse-cost-dashboard.png
captures/langfuse-widget-breakdown.png
captures/grafana-dashboard.png
captures/grafana-trace-link.png
captures/langfuse-trace-from-link.png
trace 82a8d6531b071502912ecb0c7c52d331
# run finished 2026-11-23 20:06:08 KST
exit=0
```

## Re-run after renaming the panel files (2026-11-23 20:12–20:16 KST)

CI's `SQL parse` job parses every tracked `.sql`, and the panel files hold Grafana macros, so `sql/*.sql` and
`sql-fixes/*.sql` became `*.sql.tmpl`; `build_dashboard.py`, `05-measure.py` and `07-check.py` read the new names.
`02-seed.py` found the window seeded and sent nothing; every other step ran again: `07-check.py` 15 PASS, `--fault` 1 FAIL,
`08-captures.mjs` wrote the same five screenshots (the committed ones were kept). Measurements: `results/*-2016.md`.

```text
✓ already seeded: 3659 traces in 2026-11-09 … 2026-11-22 KST (--force sends again)
✓ Grafana 13.2.6, grafana-clickhouse-datasource 4.23.5, ClickHouse 26.8.22.13
✓ lab_langfuse_ch_dashboard.events_core: 10977000 rows, 3659000 traces, 1.01 GiB on disk; scores: 1881000 (192 s)
✓ all checks passed
✗ loan-advisor failure %: v2 at least twice v3 {1: 1.47, 2: 1.66, 3: 7.14}
✗ 1 check(s) failed
# run finished 2026-11-23 20:16:54 KST
```
