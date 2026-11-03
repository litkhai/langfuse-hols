# Run log — 2026-11-03 (steps 01–12)

Environment: macOS (Darwin 25.6), Docker 29.9.2, kind 0.33.0 (node v1.37.0, one node), Helm 4.3.1,
kubectl 1.36.1, Python 3.12, `langfuse-k8s` @ `15f31e8`. Another kind cluster ran on the same Docker
during the run. Pins: [README](README.md#pins-read-2026-11-03).

## 02 — chart 1.5.41, Langfuse 3.172.1

Images: `bitnamilegacy/clickhouse:25.2.1-debian-12-r0`, `bitnamilegacy/postgresql:17.3.0-debian-12-r1`,
`bitnamilegacy/valkey:8.0.2-debian-12-r2`, `bitnamilegacy/minio:2024.12.18-debian-12-r1`,
`bitnamilegacy/zookeeper:3.9.3-debian-12-r8`, `langfuse/langfuse(-worker):3.172.1`. ClickHouse 25.2.1.3085,
Postgres 17.3, `wal_level=logical`.

## 03 — data on 3.172.1

2 prompts, 1 dataset (4 items), 1 experiment run, 40 SDK 3.15.0 traces, 10 legacy-API traces.
ClickHouse: traces 54, observations 134, scores 40, dataset_run_items_rmt 4. S3 objects 110.

## 04 — 3.225.15 on chart v1

- First run: after `helm upgrade`, `20261022_encrypt_legacy_webhook_headers` (no envGate) stayed
  unfinished; the worker log had one line, `[Background Migration] No background migrations to run`
  (09:59:42Z). The worker checks at start, and web had not inserted the row yet. After
  `rollout restart deploy/langfuse-worker` it finished at 10:11:33Z. The step now restarts the worker
  after web.
- Gate on 3.225.15: 16 rows; 10 finished, 1 finished after the restart, 5 unfinished with
  `args.envGate` (`20260701_v4_step_1..4` → `LANGFUSE_BACKGROUND_MIGRATION_V4_ENABLE_HISTORIC_BACKFILL`,
  `step_5` → `..._DROP_PID_TID_SORTING_TABLES`). The UI shows these five as **Queued**
  (screenshot `v3-background-migrations`). The upstream query `WHERE finished_at IS NULL` therefore
  never returns 0 rows on 3.225.x; non-gated unfinished = 0, failed = 0.
- ClickHouse schema version 37.
- Then `03-seed-v3.sh v3-latest`: +40 SDK traces, +10 legacy. Totals before 05: traces 104,
  observations 264, scores 80, S3 objects 211.

## 05 — chart v1 → v2 (sibling), traffic 1 trace/s

- Dry run first: the script picked image tag **3.224.1** (chart appVersion) while v1 ran 3.225.15
  (set with `--set` in 04). Passed `--image-tag 3.225.15`. Its "kube-context" log line printed the
  kubeconfig's current context (`kind-langfuse-aks`, another cluster), but its commands used
  `--context kind-lf-upgrade`.
- `quay.io/minio/mc:latest` (script default): HTTP 401 from quay.io; `minio/mc` on Docker Hub does not
  exist. Used `bitnamilegacy/minio:2024.12.18-debian-12-r1`, which ships `mc` (DEVELOPMENT.2024-11-21).
- Run 1 (`--yes`, no `--force`): sibling install, logical replication, `mc mirror`, `remote()` sync
  done; at the freeze it scaled v1 web to 0, then stopped:
  `error: v1 Redis queue depth is still 4 after 60s`. The 4 were BullMQ repeatable-job entries in
  `:delayed` (mixpanel, posthog, blobstorage integrations, data-retention), next run in hours;
  `wait`+`active` = 0. v1 web stayed at 0 while this was diagnosed.
- Run 2 (`--yes --force`, resume): 215 s wall time (1793701756 → 1793701971), including the online
  passes again, the 60 s drain wait, final deltas, v2 scale-up; Service `langfuse-app` retargeted at
  1793701954; first 2xx after it at 1793701967.
- Traffic: 1004 requests, 339 HTTP 207, 665 failed (HTTP 000, no endpoint). Failure window 682 s
  (1793701280 → 1793701961), i.e. from run 1's v1 web scale-down to the retarget. It includes the
  stop and its diagnosis; the freeze of run 2 alone falls inside its 211 s from start to first 2xx.
- The traffic pod's `sh` ignored SIGTERM, so it kept writing ~30 s after the log was read (v2 shows
  more traffic traces than the log). `traffic.sh stop` now uses a stop file.

## 06 — verify chart v2 + 3.225.15: all PASS

Images: `postgres:18` (18.6), `valkey/valkey:8.0`, `chrislusf/seaweedfs:4.23`,
`clickhouse/clickhouse-server:26.8.36.3`, `clickhouse/clickhouse-keeper:26.8.36.3`,
`docker.langfuse.com/langfuse/langfuse(-worker):3.225.15`.

| Check | v1 before | v2 after |
|---|---|---|
| pg users / orgs / projects / api_keys | 1 / 1 / 1 / 1 | same |
| pg prompts / datasets / dataset_items / dataset_runs | 2 / 1 / 4 / 1 | same |
| pg api_keys hash (md5 of hashed_secret_key) | `143c1834…` | same |
| ch traces / observations / scores / dataset_run_items_rmt | 104 / 264 / 80 / 4 | 453 / 264 / 80 / 4 (traces + traffic) |
| S3 objects | 211 | 567 |
| accepted traffic traces on v2 | 339 | 339 |

Old API keys: `GET /api/public/projects` 200, `GET /api/public/traces/<id>` 200; password sign-in as
the v1 admin: session for `admin@example.com`.

## 07 — 4.72.0, legacy: all PASS

- Gate 0 / 0. `pg_dump -Fc` 308598 bytes.
- ClickHouse schema 37 → **53**. Postgres `traces observations scores dataset_run_items` → dropped.
  ClickHouse before: `dataset_run_items dataset_run_items_rmt event_log observations project_environments scores traces`;
  after: `dataset_run_items_rmt events_core events_full observations observations_batch_staging scores traces`.
- SDK 3.15.0 ×10, SDK 4.17.0 ×10, legacy API ×5 → +25 in `traces`, 0 in `events_full`.
- `GET /api/public/traces`, `/observations`, `/metrics/daily` 200; `GET /api/public/v2/observations` 404.
- Worker health: `eventPropagation.enabled=false`, `queueConsumption.enabled=true`,
  `thresholdSeconds` 3600 (queue) and 2100 (propagation).

## 08 — dual: all PASS

- Right after the writes: +25 in `traces`; SDK 4.17.0 traces in `events_full` 10/10; SDK 3.15.0 0/10,
  legacy API 0/5; `observations_batch_staging` 50 rows (partition by 3-minute window, TTL 48 h).
- Worker log every minute: `[DUAL WRITE] No partitions available for processing` until the window
  was eligible. SDK v3 and legacy traces all in `events_full` **557 s** after the writes.
  Health: `propagationDelaySeconds` 671, `lastProcessedPartition` 2026-11-03 10:39:00.
- `GET /api/public/traces` 200 and `GET /api/public/v2/observations` 200. Pre-dual traces in
  `events_full`: 0/40 (no backfill yet).
- UI: "New data in ~15 min" next to the title, "Action required" in the sidebar (`v4-dual-traces`).

## 09 — rollback rehearsal: all PASS

- a) image 3.225.15 without a rewind: new web pod restarts=3, not ready, log
  `error: no migration found for version 53: read down for version 53 .: file does not exist`
  (the guide quotes version 46).
- b) back on 4.72.0 (schema 53). `CLICKHOUSE_CLUSTER_ENABLED=true` on chart v2 (single replica), so
  the clustered command: `migrate … goto 37` ran 53 → 37 (38–42 down ~8 s each); events tables 0.
- c) 3.225.15 up; `GET /api/public/traces/<trace written by SDK v4 on dual>` 200; +5 SDK v3 traces.
- d) 4.72.0, dual again: schema 53, `events_full` 0 rows. What dual had written to `events_full` is
  gone with the rewind; it stays in the old tables and comes back with the backfill.

## 10 — backfill: all PASS

- Before: traces 527, observations 409, `events_full` 0; ClickHouse `default` 282.87 KiB.
- Steps 1–4 finished **225 s** after enabling; step 5 (drop scratch) stays unfinished (its own gate).
- Traces without a root in `events_full`: 0. Observations missing from `events_full`: 0. Virtual root
  spans (`t-<trace_id>`): 527.
- One SDK v3 trace: the virtual root carries the trace metadata (`phase`, `producer`); the child events
  (`retrieve-context`, `answer`, and the SDK's own `support-request` span) carry user and session but
  not that metadata, as the guide says. Each SDK trace now has two `support-request` rows: the SDK's
  root span and the virtual root. Not looked into yet.

- UI on 4.72.0 after the backfill: the background-migrations page lists steps 1–4 Finished, step 5
  Queued (its own gate), and no longer lists the 2024 rows (`20241024_*`, `20250417_*`, `20250814_*`)
  that 3.225.15 showed.

## 11 — events_only (cutover)

- SDK 4.17.0 ×10 and SDK 3.15.0 ×10 → +20 traces in `events_full`, +0 rows in `traces`. SDK 3.15.0
  (OpenTelemetry-based) is **not** rejected on events_only; the guide rejects Python SDK v2 and older.
- Legacy API: `POST /api/public/ingestion` with `trace-create` → 207 with a per-event 400,
  `Event type "trace-create" is not accepted by /api/public/ingestion when LANGFUSE_MIGRATION_V4_WRITE_MODE is events_only. This endpoint only accepts score events.`
  The web log has a `warn` per request (`Rejected 2 event(s) … These events were not stored`).
- 404: `GET /api/public/traces`, `/observations`, `/sessions`, `/scores`, `/v2/scores`,
  `/metrics/daily`, `/dataset-run-items`, `/datasets/<name>/runs`; `POST /api/public/traces`, `/spans`,
  `/generations`, `/events`.
- 200: `GET /api/public/v2/observations?traceId=<v3-era trace>` (4 rows: the virtual root, the SDK's
  root span, `retrieve-context`, `answer`), `GET /api/public/v3/scores`, `GET /api/public/v2/metrics`.
- `GET /api/public/experiments` without `fromStartTime` → 400 (`fromStartTime is required`); the step
  was fixed and that one call re-run by hand: 200, the v3-era run `baseline-3.15.0 - …` with
  `itemCount` 4.
- Worker health after the cutover: `stuck=false` for both checks, although
  `propagationDelaySeconds` 3733 > `thresholdSeconds` 2100 (nothing to propagate on events_only).
- UI (`v4-events-only-v3-era-trace`): the v3-era trace opens with the virtual root `support-request`
  and, under it, the SDK's own `support-request` span.

## 12 — storage cleanup

- First run failed at once: `kubectl create configmap` does not take `--from-env-file` together with
  `--from-literal`. Fixed (merged env file), re-run.
- Before: events_core 176.66 KiB, events_full 185.99 KiB, observations 52.32 KiB,
  observations_pid_tid_sorting 56.47 KiB, traces 38.63 KiB.
- `LANGFUSE_BACKGROUND_MIGRATION_V4_DROP_PID_TID_SORTING_TABLES=true` + worker restart: step 5
  finished, scratch tables 0. `TRUNCATE TABLE traces|observations ON CLUSTER default`
  (`CLICKHOUSE_CLUSTER_ENABLED=true`).
- After: events_core and events_full unchanged; traces and observations have no active parts.
  `GET /api/public/v2/observations?traceId=<v3-era trace>` → 200, 4 observations.
