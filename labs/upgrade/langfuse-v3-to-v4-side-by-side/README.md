# Langfuse v3 → v4 side by side: a second release on the same data layer

[English](#english) | [한국어](#한국어)

---

## English

The in-place path ([langfuse-helm-v3-to-v4](../langfuse-helm-v3-to-v4/README.md)) upgrades one
deployment through `legacy`, `dual`, a backfill and `events_only`. This lab is for an operator who
cannot afford that long in-place window and wants to move **side by side** instead:

1. Keep the existing data layer (ClickHouse, Postgres, Redis, S3-compatible store), deployed apart
   from the Langfuse charts. Upgrade ClickHouse **in place** first; v3 keeps running on it.
2. Create a **separate v4 database in the same ClickHouse cluster** and install a **second release**
   (chart v2, Langfuse 4.82.0) next to the running v3 release (chart 1.5.41, Langfuse 3.172.1).
3. Copy the data with scripts, let v4's own backfill build its tables, test v4 on it.
4. Copy what v3 wrote since (delta), switch the client endpoint, check that nothing is lost, keep
   a rollback path, shut v3 down.

Everything runs end to end on a local kind cluster, under one OpenTelemetry trace per second.
Every number below names the run it comes from.

### Short answers

| # | Question | Answer (measured 2026-11-18, conditions in [Results](#results-2026-11-18)) |
|---|---|---|
| 1 | ClickHouse version-up | Chart 1.5.41 bundles **ClickHouse 25.2.1** (`bitnami/clickhouse:25.2.1-debian-12-r0`, read from the chart). In place to **26.8.39.19**: ClickHouse was down **33 s** (25.8 s of it pulling the image; 8 s in the first run with the image cached); v3 lost **0 of 107** traces sent through it, because v3 web only writes to S3 and the queue and the worker retries. **But 26.8 breaks every Langfuse v3 before 3.225.7**: it reads their millisecond timestamps as seconds, so `created_at`, `updated_at`, `event_ts` become 9999-12-31 (first run: 83 of the 98 traces written from the upgrade window on). Fix: `input_format_read_datetime_number_as_raw_value = 1` in the ClickHouse profile, in the same rollout as the new image. With it: 0 bad rows, v3 ingests and reads. |
| 2 | v4 in a separate database | `CLICKHOUSE_DB=langfuse_v4`. The database must exist first (`CREATE DATABASE … ON CLUSTER`; the migrations do not create it). v4 then applies its 56 ClickHouse migrations to an empty database. Copy = `INSERT INTO langfuse_v4.<t> SELECT <common columns> FROM default.<t>` for `traces`, `observations`, `scores`, `dataset_run_items_rmt`, `blob_storage_file_log` (3.5 s for 766 rows), then v4's own historic backfill (`20260701_v4_step_1..4`, gate `LANGFUSE_BACKGROUND_MIGRATION_V4_ENABLE_HISTORIC_BACKFILL`) writes `events_full` in **193 s**. Old traces show in the v4 UI and API, nothing missing. |
| 3 | Postgres | **(b) new database on the same server, from a dump** is the recommendation; (a) a new instance works the same (dump+restore 0.7 s, v4 restart incl. 94 migrations 27 s). (c) sharing v3's database **works on this data set** (v3.172.1 keeps serving through v4's 94 migrations; reads and writes keep working on both) but leaves v3's worker failing on v4's background-migration rows, makes every PG change irreversible for v3, and shares the users/keys tables with no way back. 94 Prisma migrations between the versions; the destructive ones drop the legacy Postgres `traces`, `observations`, `scores`, `dataset_run_items` (unused by 3.172.1). v4 needs PG ≥ 15 (16 recommended). |
| 4 | Redis | One instance is fine, **one keyspace is not**: with no prefix, v4's worker takes v3's ingestion jobs: of 30 traces sent to v3, only 8 were stored by v3 and 22 by neither (first run: 6 by v3, 20 in v4's database, 4 nowhere). `REDIS_KEY_PREFIX` on v4 (or another db index) separates them completely (30/30 and 20/20). v4 needs Redis ≥ 7.0 (7.2 recommended) or Valkey ≥ 8; the Valkey 8.0.2 of chart 1.5.41 qualifies. |
| 5 | Object storage | One bucket, separate prefixes for new files (`v4/events/`, `v4/media/`). Media rows keep their own bucket and path, so a v3 attachment copied with the Postgres dump is served by v4 unchanged (sha256 match). Copy `blob_storage_file_log` too, so v4 can delete v3-era event files. |
| 6 | Secrets | Same `SALT`, `ENCRYPTION_KEY`, `NEXTAUTH_SECRET` (one Secret both releases read): v3's API key, a v3 session cookie and the LLM key v3 encrypted all work on v4. Negative controls with a different set: API key **401**, session cookie rejected (`user: null`), LLM key not decrypted (`Unsupported state or unable to authenticate data`, nothing reached the mock model). |
| 7 | Cutover | Ingestion switch = one Service selector change: **0 of 396 requests failed**, last trace on v3 at 07:18:38, first on v4 at 07:18:39 (the traffic's 1 s resolution). Read gap (v3's last minutes not yet in v4): **187 s** (final delta copy 1.6 s + backfill re-run of the month's partition 173 s). Data-loss check: **396/396** accepted traces in v4 (195 through v3, 201 straight to v4), 0 v3 traces, observations or scores missing. Rollback rehearsal: 30 s back on v3 and forward again, 0 of 260 failed, the 29 traces v3 took copied afterwards. v4 accepts OTel SDKs (Python SDK 3.15.0 and 4.17.0, 5/5 each); the legacy `/api/public/ingestion` answers 207 with a per-event 400 for traces (`Event type not accepted`; scores only). |

### Path

```
data layer (02): ClickHouse 25.2.1 (1 shard × 1 replica, Keeper), Postgres 17.3, Valkey 8.0.2, MinIO — not in any chart
lf-v3 (03): chart 1.5.41, Langfuse 3.172.1   ClickHouse db default   Postgres db langfuse      Redis db 0, no prefix
  │ 05  ClickHouse 25.2.1 → 26.8.39.19 in place (+ the timestamp setting), v3 keeps running
  │ 06  Postgres option (b): pg_dump langfuse → langfuse_v4; CREATE DATABASE langfuse_v4 ON CLUSTER
lf-v4 (06): chart 2.2.5, Langfuse 4.82.0     ClickHouse db langfuse_v4  Postgres db langfuse_v4  Redis db 0, prefix lf-v4
  │ 07  INSERT … SELECT default.* → langfuse_v4.*; v4's historic backfill → events_full
  │ 08  Postgres option (a): v4 on a new instance (17.12), then back to (b)
  │ 09  Postgres option (c), Redis sharing, wrong secrets: on a scratch pair lf-v3c / lf-v4c
  │ 10  delta copy · final Postgres copy · switch langfuse-app → lf-v4 · final delta · rollback rehearsal · v3 to 0
lf-v4 serves; lf-v3 scaled to 0 with its databases kept
```

### Pins (read 2026-11-18)

| What | Version | Source |
|---|---|---|
| Langfuse | 3.172.1 → 4.82.0 (latest v4, published 2026-11-17T14:28Z) | `gh release list langfuse/langfuse` |
| Charts | 1.5.41 (last v1) and 2.2.5 (latest v2, appVersion 4.80.0; image tag set to 4.82.0) | `oci://ghcr.io/langfuse/langfuse-k8s/charts/langfuse` |
| ClickHouse | 25.2.1.3085 → 26.8.39.19 (newest 26.8 LTS patch, 2026-11-17) | chart 1.5.41 `charts/clickhouse/values.yaml`; Docker Hub tags |
| Postgres | 17.3 (what chart 1.5.41 bundles) · 17.12 for option (a) | chart 1.5.41 `charts/postgresql/Chart.yaml`; Docker Hub |
| Valkey / MinIO | 8.0.2 · `bitnamilegacy/minio:2024.12.18-debian-12-r1` (both what chart 1.5.41 bundles) | chart 1.5.41 subcharts |
| Python SDK | 3.15.0 (v3 producers) and 4.17.0 | this repository's track pins |
| Upstream source read | langfuse `v3.172.1` and `v4.82.0` tarballs; langfuse-docs `aabc0c6` (2026-11-18) | codeload.github.com, raw.githubusercontent.com |

### Prerequisites

Docker with about 10 GB free for the kind node, `kind`, `kubectl`, `helm` ≥ 3.17, `jq`, `openssl`,
Python 3.10+ (`PYTHON=python3.12` by default). Optional: Playwright for `shots.sh`
(`PLAYWRIGHT_DIR=<dir with node_modules/playwright>`).

### Steps

Run them in order from this directory. Each step checks its own result and exits non-zero on a FAIL.

| Step | What it does | Answers |
|---|---|---|
| `01-cluster.sh` | kind cluster, the app Secret both releases read, SDK virtualenvs | — |
| `02-data-layer.sh` | `data-layer.yaml`: ClickHouse 25.2.1 as a one-replica cluster `default` with Keeper, Postgres 17.3, Valkey 8.0.2, MinIO | — |
| `03-install-v3.sh` | `lf-v3`: chart 1.5.41, Langfuse 3.172.1, every store external (`values/v3.yaml`); the client Service `langfuse-app`, a mock LLM, a curl pod (`helpers.yaml`) | — |
| `04-seed-v3.sh` | prompts, a dataset and an experiment run, 40 SDK v3 traces with scores, 10 legacy-API traces, a media attachment, an LLM connection | — |
| `05-ch-upgrade.sh` | ClickHouse → 26.8.39.19 in place under traffic, with the timestamp setting (`CH_DATETIME_FIX=0` reproduces the failure); v3 ingest and read checks | 1 |
| `06-v4-release.sh` | Postgres (b), `CREATE DATABASE langfuse_v4`, `lf-v4` (`values/v4.yaml`, overrides in the ConfigMap `lf-v4-env`); v3 API key, session cookie, LLM key and media on v4 | 2, 3, 5, 6 |
| `07-copy-and-backfill.sh` | `copy-ch.sh initial`, then v4's historic backfill; v3 vs v4 counts, old traces through v4's API and UI | 2 |
| `08-pg-new-instance.sh` | Postgres (a): `pg-new.yaml`, dump → restore across instances, v4 on it, back to (b) | 3 |
| `09-pg-shared.sh` | scratch pair `lf-v3c`/`lf-v4c`: Postgres (c), Redis with and without a key prefix, a wrong secret set | 3, 4, 6 |
| `10-cutover.sh` | delta copy, final Postgres copy, switch, drain, final delta, no-loss check, rollback rehearsal, SDK checks, v3 to 0 | 7 |
| `99-cleanup.sh` | deletes the cluster and `.work/` | — |
| `copy-ch.sh`, `rebackfill.sh`, `traffic.sh`, `inventory.sh`, `produce.py`, `ui.py`, `shots.sh` | helpers the steps call | — |

### Results (2026-11-18)

Verified on Langfuse v3.172.1 → v4.82.0 / SDK 3.15.0 and 4.17.0 / CH 25.2.1.3085 → 26.8.39.19 /
PG 17.3 (option a: 17.12) / Valkey 8.0.2 / MinIO 2024.12.18, charts 1.5.41 and 2.2.5, kind 0.33.0
(Kubernetes 1.37.0, one node), Helm 4.3.1, Docker 29.9.3 (VM 12 CPUs, 15.6 GiB) on an Apple M4 Pro.
Steps 01–10 ran end to end on a new cluster (logs in [results/](results/)). 08 stopped on its
first try on a Postgres start-up race (fixed in the script) and was re-run after 09; 08 and 09 do
not depend on each other. The data set is a few hundred traces, so durations show the mechanisms,
not sizing. After the run the logs were masked (the lab Postgres password, one public key, host paths) and
the two print lines that wrote them in 06 and 09 were changed to match; nothing else changed.

| Step | Result |
|---|---|
| 03 v3 | chart 1.5.41 install 77 s (plus a worker restart, finding 2); ClickHouse schema 34, 391 Prisma migrations |
| 04 seed | 55 traces, 134 observations, 40 scores, 4 dataset run items, 1 media file, 1 LLM connection; 10/10 background migrations finished |
| 05 ClickHouse | 25.2.1.3085 → 26.8.39.19: rollout 32.9 s, `/ping` failing for 33 s (image pull 25.8 s of it; first run with the image cached: 8 s). 107/107 traffic traces sent during the window stored; worker logged 192 `ECONNREFUSED` and 57 timeouts and retried. After: schema 34 unchanged, not dirty; 0 rows after 2200; 15/15 new traces; v3 traces, observations, scores, sessions, daily metrics APIs 200. Without the setting (first run): 83 of the 98 traces from the upgrade window on dated 9999-12-31 |
| 06 v4 | Postgres (b) dump+restore 0.6 s (455 KB); `lf-v4` install 64.7 s; ClickHouse schema 56 in `langfuse_v4`; 94 Prisma migrations; legacy Postgres tables gone; 1 background migration failed on the install race and finished after the reset. v3 key 200 (wrong secret 401), v3 session cookie accepted (tampered: rejected), v3-encrypted LLM key decrypted (mock got `sk-mock-sbs-lab-0001`), v3 media served with matching sha256 |
| 07 copy + backfill | 766 rows in 3.5 s; backfill steps 1–4 in 193.1 s; v3 177 traces / 276 observations / 50 scores, v4 177 distinct traces, 0 traces and 0 observations missing, 177 virtual roots; old trace: 4 observations (virtual root + SDK root + 2), its score, the experiment, prompt and dataset on v4's API; same trace in v4's UI ([results/v4-v3-trace.png](results/v4-v3-trace.png), v3's view: [results/v3-v3-trace.png](results/v3-v3-trace.png)) |
| 08 Postgres (a) | dump → restore across instances 0.7 s; v4 restart with 94 migrations 26.9 s; key, prompt, old trace OK; back to (b) 26.9 s |
| 09 Postgres (c) | v4c install with 94 migrations on v3c's live database 47.5 s; v3c 60/60 probes 200 during it; v3c reads/writes 7/7 PASS; key created on v3c works on v4c; v3c restart clean; v3c worker `Cannot find module './createRootSpansFromTraces'` |
| 09 Redis | no prefix: 30 to v3c → 8 in v3c, 0 in v4c, 22 nowhere; 20 to v4c → 20 in v4c. `REDIS_KEY_PREFIX=lf-v4c`: 30/30 and 20/20, 0 crossed |
| 09 wrong secrets | API key 401; v3 session cookie `user: null`; LLM key `Unsupported state or unable to authenticate data` |
| 10 cutover | delta under live v3: 20 traces, re-backfill 143 s; final Postgres copy 1.1 s + v4 restart on it 29 s; switch: 0/396 failed, v3 → v4 within 1 s; v3 queues empty 0.2 s after; final delta 175 traces, re-backfill 173 s, read gap 187 s; 396/396 in v4, 0 missing; rollback 30 s on v3 (29 traces), forward, re-backfill 202 s, 260/260 in v4; SDK 3.15.0 and 4.17.0 accepted, legacy trace-create 400; v1 `traces`, `observations`, `metrics/daily` 404, `v2/observations`, `v3/scores` 200; v3 scaled to 0, health 4.82.0. Timeline: [results/cutover-timeline.txt](results/cutover-timeline.txt); final state: [results/final-checks.txt](results/final-checks.txt) |

### Cutover procedure

Measured in `10` (timestamps in [results/cutover-timeline.txt](results/cutover-timeline.txt)); before it,
`06`–`07` did the initial copy while v3 served (Postgres dump 0.6 s, v4 install 65 s, ClickHouse copy
3.5 s, backfill 193 s), and v4 was tested on it.

1. **Delta while v3 serves** — `copy-ch.sh delta` (rows with `event_ts` after the saved watermark),
   then `rebackfill.sh <yyyymm>` for the partitions they fall in. 20 traces: copy 2.6 s, re-backfill
   143 s. Repeat until the delta is small; it shortens nothing below the re-backfill time (finding 5).
2. **Final Postgres copy** — dump v3's database into a new database (1.1 s), point v4 at it with the
   backfill gate off, mark the backfill chain finished, gate on (29 s). v4 is not serving yet, so
   clients see nothing. From here, changes made in v3's UI (prompts, datasets, keys) are not carried
   over: freeze them for the next minutes.
3. **Switch** — move the client endpoint (here the Service `langfuse-app`) to v4 web. 0 of 396
   requests failed; the last trace v3 took and the first v4 took are 1 s apart.
4. **Drain v3** — wait until v3's BullMQ `wait`/`active` lists are empty (0.2 s here), plus one
   ClickHouse write interval (10 s).
5. **Final delta** — `copy-ch.sh delta` (175 traces, 1.6 s) and `rebackfill.sh` (173 s). Until it
   finishes, the traces of the last minutes before the switch are in v4's database but not yet
   visible: the read gap, 187 s from the switch.
6. **No-loss check** — every accepted trace id in `events_full` (396/396), every v3 trace, observation
   and score in v4 (0 missing).
7. **Rollback, if needed** — point the endpoint back to v3 (v3's databases were never touched; the
   rehearsal ran 30 s on v3 with 0 failures). v3 does not have what v4 received meanwhile. Going
   forward again = switch back, then a delta and a re-backfill for the rollback window (29 traces,
   202 s; 260/260 in v4).
8. **Shut v3 down** — scale web and worker to 0 and keep the release, `default` and `langfuse` for a
   while; remove the ClickHouse timestamp setting once no v3 < 3.225.7 writes any more. Drop them
   later.

### Which Postgres option

| Option | How | Measured | Verdict |
|---|---|---|---|
| (a) new instance | `pg_dump -Fc` on v3's server piped into `pg_restore` on a new one (17.12) | dump+restore 0.7 s; v4 restart incl. 94 migrations 26.9 s; API key, prompts, old traces OK | works; choose it when the server should change too (major version, size, a managed service) |
| (b) new database, same server | `CREATE DATABASE langfuse_v4`, `pg_dump | pg_restore` | dump+restore 0.6 s (455 KB dump); v4 install 64.7 s | **recommended**: no new server, v3's database untouched (rollback = point clients back), the dump is repeated at the cutover |
| (c) shared database | v4 on v3's database | v3 kept serving during and after the 94 migrations | works on this data set, but v3's worker errors on v4's rows (finding 7), every v4 change is applied to v3's only database, and rolling back means restoring a backup |

Why (b): the side-by-side value is that v3 keeps an untouched copy of everything until v3 is
switched off. (c) gives that up for Postgres, which is the cheaper of the two copies (seconds for
a few hundred KB here; Postgres holds metadata, not traces). Re-dump at the cutover so v4 gets what
users changed on v3 in the meantime (`10`, step 2). v4 needs PG ≥ 15 (16 recommended,
[postgres.mdx](https://github.com/langfuse/langfuse-docs/blob/aabc0c6d9c309db6efda220d06aa05967d6c5ff6/content/self-hosting/deployment/infrastructure/postgres.mdx));
the 17.3 that chart 1.5.41 bundles qualifies.

The 94 Prisma migrations between 3.172.1 (391 applied) and 4.82.0 (485): the ones that remove data
or schema are `20260723124010_drop_dataset_run_items_table` and `20260723150000_drop_legacy_tracing_tables`
(Postgres `dataset_run_items`, `traces`, `observations`, `scores`, plus the rows of the
background migrations that emptied them), `20261109110453` (drops an `annotation_queue_items`
index after `20261109110421` adds its replacement), and drops of columns and indexes on tables that
only v4 has (`monitors`, `slack_integrations` pending columns, `gateway_ai_connections`,
`verified_domains`). 3.172.1 does not read the dropped tables at runtime (source grep; `(c)` in 09
kept working). `20260821121500_backfill_evaluator_v2`, `20260924213400_backfill_role_assignments`
and `20261022120000_backfill_user_role_assignments` copy v3 rows into new tables once.

### Findings

1. **ClickHouse 26.8 corrupts the timestamps of Langfuse v3 before 3.225.7.** 26.8 changed
   `input_format_read_datetime_number_as_raw_value` from 1 to 0 (`system.settings_changes`). Those v3
   releases send `DateTime64(3)` values as bare millisecond integers; 26.8 reads them as seconds, so
   `created_at`, `updated_at`, `event_ts` (and observation `start_time`/`end_time`) are stored 1000×
   too large and shown as `9999-12-31 23:59:59`. In the first run 83 of the 98 traces (and 103 observations)
   that v3.172.1 wrote from the upgrade window on were affected ([results/first-run-datetime.txt](results/first-run-datetime.txt)).
   Upstream: [langfuse#16858](https://github.com/langfuse/langfuse/issues/16858), fixed in 3.225.7
   ([#16957](https://github.com/langfuse/langfuse/pull/16957)). The upgrade guide says v3 releases
   are "fully compatible with current ClickHouse versions"; for v3 < 3.225.7 on ClickHouse ≥ 26.8
   they are not. Fix used here: a `users.d` profile with the setting set to 1, mounted in the same
   rollout as the new image (`05-ch-upgrade.sh`), so the first query on 26.8 already has it. The
   setting applies to every user of that profile; v4.82.0 ran with it and wrote no bad rows (it
   sends strings). Rows already written are recoverable (the stored value is ×1000, not clamped):
   `copy-ch.sh` divides values after 2200 by 1000 while copying to v4. In v3's own tables they stay
   wrong (the timestamp is in the sorting key, so `ALTER … UPDATE` cannot fix it).
2. **First v4 install: a background migration fails for good on a race.** Helm starts web and worker
   together. Web runs the Prisma migrations, then the ClickHouse ones; the worker already runs the
   background migrations, and `20261110_backfill_audit_logs_to_clickhouse` failed with
   `ClickHouse audit_logs table does not exist` 22 s before web created that table (both runs). A
   failed row is never retried. `06` clears `failed_at` and restarts the worker. Same class as the
   in-place lab's finding 2: on the first v3 install the worker started before the Prisma tables
   existed (`The table public.background_migrations does not exist`) and ran nothing until restarted.
3. **The v4 database must exist before v4 starts.** `clickhouse/scripts/up.sh` passes
   `database=${CLICKHOUSE_DB}` to golang-migrate and does not create it. The documented v4 grants are
   written for `default.*` and `default.observations_pid_tid_sorting`; with a separate database they
   apply to `langfuse_v4.*` (not tested with a restricted user: the lab user has full rights).
4. **Re-running the backfill shows every row twice until a merge.** The backfill can be re-run for
   chosen partitions (`args.partitions`), which is how the deltas reach `events_full` here. It
   rewrites the whole partition; `events_full`/`events_core` are ReplacingMergeTree, but
   `/api/public/v2/observations` does not deduplicate, so a trace listed 7 observations instead of
   4 in the first run until `OPTIMIZE … PARTITION … FINAL`. `rebackfill.sh` runs that afterwards.
   The guide's "re-runs … are de-duplicated" holds only after merges.
5. **The backfill has a fixed cost per chunk.** Each chunk waits for the query to be confirmed
   running and then polls every 30 s (`pollIntervalMs`, overridable in the row's `args`): steps 1–4
   took 193 s for 177 traces in one partition. `rebackfill.sh` sets 2 s; the three delta re-runs still took 143, 173 and 202 s.
   It scales with partitions and parts, not with the delta, so plan the read gap from the size of
   the current month's partition.
6. **The salt must match; the bcrypt fallback does not cover a changed salt.** v4.82.0 looks an API
   key up by `sha256(secret + SALT)`; the bcrypt check runs only for keys that have no fast hash yet
   (`web/src/features/apiKey/verifier.ts`). With another salt the v3 key got **401** (09).
7. **Shared Postgres (c): v3.172.1's worker trips over v4's background-migration rows.** 3.172.1's
   manager has no `envGate` filter, so it picks v4's gated `20260701_v4_step_*` rows and fails with
   `Cannot find module './createRootSpansFromTraces'` every run; any later v3 background migration
   would be blocked behind it. Everything else held on this data set: v3.172.1 served during v4's 94
   migrations (59/59 health and prompt probes 200), restarted cleanly (`No pending migrations to
   apply`), read and wrote prompts, dataset items and API keys; six v3 UI calls (tRPC) returned 200
   (`evals.allConfigs` got 400 for the lab's request shape, not checked further). An API key created on v3 after the
   migration has no `role_assignments` row; v4.82.0 creates it on first use (`backfillRoleAssignments`,
   marked deprecated, "will be removed in the next major version").
8. **One Redis keyspace for two releases loses data.** Both use the same BullMQ queue names. With no
   prefix, v4's worker consumes v3's ingestion jobs. Of 30 traces sent to v3 (20 SDK v3, 10 legacy
   API), v3 stored 8 and 22 were stored nowhere (final run); in the first run v3 stored 6, v4 stored
   20 in its own database and 4 were lost. Where they go varies, that they leave v3 does not. The
   key scan shows both releases on the same `bull:<queue>` keys (09). `REDIS_KEY_PREFIX` on v4 (works in cluster mode
   too, as a hash tag) or a separate db index removes it: 30/30 and 20/20, 0 crossed.
9. **Not every v3 table has a v4 counterpart.** `event_log`, `project_environments` and the old
   `dataset_run_items` are dropped by v4's migrations on an in-place upgrade; a fresh v4 database
   never has them, so they are not copied. v4's schema has every column of the five copied tables
   (none lost).
10. **The "latest v3 first" prerequisite moves to v4.** The guide requires the latest v3 and all
    background migrations finished before v4, because v4's migrations drop Postgres tables those
    migrations emptied. 3.172.1 had all of its own finished (10 rows); the late-v3 migrations it does
    not have (`20261022_encrypt_legacy_webhook_headers`, `20261110_backfill_audit_logs_to_clickhouse`)
    were added and run by v4 on its own database.

### What the official procedure assumes, and what this lab changed

- **The upgrade guide** upgrades one deployment in place: the same `CLICKHOUSE_DB`, the same Postgres
  database, write modes `legacy` → `dual` → backfill → `events_only`. The backfill reads the old
  tables of the database v4 runs on. Here v4 never writes the old tables; they only receive the
  copies from v3, the backfill converts them, and v4 runs `events_only` from the start. `dual` and
  `legacy` are not used.
- **The guide's gate** (latest v3, every background migration finished) is checked on v3.172.1's
  own migrations (finding 10).
- **The guide's rollback** (rewind the ClickHouse schema to 37, then the latest v3) is not needed:
  v3's databases are never touched by v4. Rollback = point the client endpoint back to v3, then copy
  what v4 received in the meantime, which no tool does (v4 writes `events_full`, v3 reads `traces`).
- **The backfill** is run once for the initial copy and re-run per touched partition for each
  delta (`rebackfill.sh`, findings 4 and 5), with the chain rows reset by SQL.
- **The final Postgres copy** brings the v4 backfill rows back unfinished; `10` marks them finished
  (their result is already in `langfuse_v4`) before re-running only the delta.

### Not tested here

- A ClickHouse user with only the documented grants; ClickHouse with more than one replica (the
  cluster here is 1 shard × 1 replica with Keeper); Redis cluster or Sentinel; managed services
  (RDS, ElastiCache, S3).
- Data volumes beyond a few hundred traces, and partitions other than the current month: the
  durations are mechanisms, not sizing.
- Deletions on v3 after the initial copy (a deleted trace stays in v4), evaluators and exports,
  annotation queues and comments written on v3 after the final Postgres copy.
- Python SDK v2, JS/TS SDKs: only the legacy REST call they make was sent (rejected for traces).
- The Helm upgrade of `lf-v3` itself (it stays on chart 1.5.41), Ingress/DNS: the endpoint switch
  is a Service selector, the DNS or load-balancer change in production has its own TTL.
- A reverse copy from v4 to v3 after a rollback.

---

## 한국어

in-place 경로([langfuse-helm-v3-to-v4](../langfuse-helm-v3-to-v4/README.md))는 배포 하나를 `legacy`, `dual`,
backfill, `events_only` 순서로 올립니다. 이 실습은 그렇게 긴 in-place 작업 시간을 감당할 수 없어서 **나란히
(side by side)** 옮기려는 운영자를 위한 것입니다.

1. 기존 데이터 계층(ClickHouse, Postgres, Redis, S3 호환 저장소)을 Langfuse chart와 분리해 그대로 씁니다.
   ClickHouse는 먼저 **그 자리에서** 업그레이드하고, v3는 그 위에서 계속 돕니다.
2. **같은 ClickHouse 클러스터에 v4용 데이터베이스를 따로** 만들고, 돌고 있는 v3 release(chart 1.5.41,
   Langfuse 3.172.1) 옆에 **두 번째 release**(chart v2, Langfuse 4.82.0)를 설치합니다.
3. 스크립트로 데이터를 복사하고, v4 자신의 backfill로 v4 테이블을 만들고, 그 위에서 v4를 확인합니다.
4. 그 사이 v3에 들어온 데이터(델타)를 복사하고, 클라이언트 endpoint를 바꾸고, 빠진 것이 없는지 확인하고,
   롤백 경로를 남긴 채 v3를 내립니다.

모든 단계를 로컬 kind 클러스터에서 초당 OpenTelemetry trace 하나를 계속 보내면서 처음부터 끝까지 실행합니다.
아래 수치에는 모두 어느 실행에서 나왔는지 적었습니다.

### 짧은 답

| # | 질문 | 답(2026-11-18 측정, 조건은 [결과](#결과-2026-11-18)) |
|---|---|---|
| 1 | ClickHouse 버전 업 | chart 1.5.41에 들어 있는 것은 **ClickHouse 25.2.1**(`bitnami/clickhouse:25.2.1-debian-12-r0`, chart에서 직접 확인). **26.8.39.19**로 그 자리에서 올리는 동안 ClickHouse가 **33초** 멈췄습니다(그중 25.8초는 이미지 pull, 이미지가 캐시에 있던 첫 실행은 8초). v3 web은 S3와 queue에만 쓰고 worker가 재시도하므로 v3를 거친 trace **107개 중 0개**를 잃었습니다. **하지만 26.8은 3.225.7 이전의 모든 Langfuse v3를 깨뜨립니다**: 밀리초 timestamp를 초로 읽어서 `created_at`, `updated_at`, `event_ts`가 9999-12-31이 됩니다(첫 실행: 업그레이드 구간부터 쓴 trace 98개 중 83개). 해결: 새 이미지와 같은 rollout에서 ClickHouse profile에 `input_format_read_datetime_number_as_raw_value = 1`. 적용하면 잘못된 행 0개, v3 수집·조회 정상. |
| 2 | 별도 데이터베이스의 v4 | `CLICKHOUSE_DB=langfuse_v4`. 데이터베이스를 먼저 만들어야 합니다(`CREATE DATABASE … ON CLUSTER`, migration은 만들지 않음). 그러면 v4가 빈 데이터베이스에 ClickHouse migration 56개를 적용합니다. 복사 = `traces`, `observations`, `scores`, `dataset_run_items_rmt`, `blob_storage_file_log`에 대해 `INSERT INTO langfuse_v4.<t> SELECT <공통 컬럼> FROM default.<t>`(766행 3.5초). 이어서 v4 자신의 historic backfill(`20260701_v4_step_1..4`, gate `LANGFUSE_BACKGROUND_MIGRATION_V4_ENABLE_HISTORIC_BACKFILL`)이 **193초**에 `events_full`을 채웁니다. 예전 trace가 v4 UI와 API에 보이고, 빠진 것은 없습니다. |
| 3 | Postgres | **(b) 같은 서버의 새 데이터베이스에 dump를 복원**을 권합니다. (a) 새 인스턴스도 똑같이 동작합니다(dump+restore 0.7초, migration 94개를 포함한 v4 기동 27초). (c) v3 데이터베이스 공유는 **이 데이터에서는 동작**했지만(v4의 migration 94개 동안에도 v3.172.1이 계속 응답, 양쪽 읽기·쓰기 정상) v3 worker가 v4의 background migration 행에서 계속 실패하고, Postgres 변경이 모두 v3에 되돌릴 수 없이 적용되고, 사용자·키 테이블을 되돌릴 방법 없이 함께 씁니다. 두 버전 사이 Prisma migration은 94개이고, 파괴적인 것은 예전 Postgres `traces`, `observations`, `scores`, `dataset_run_items`(3.172.1은 쓰지 않음)를 지우는 것입니다. v4는 PG 15 이상(16 권장)이 필요합니다. |
| 4 | Redis | 인스턴스 하나는 괜찮지만 **keyspace 하나는 안 됩니다**: prefix 없이 두면 v4 worker가 v3의 ingestion job을 가져갑니다. v3로 보낸 trace 30개 중 v3가 저장한 것은 8개뿐이고 22개는 어디에도 없었습니다(첫 실행: v3 6개, v4 데이터베이스 20개, 없어진 것 4개). v4에 `REDIS_KEY_PREFIX`(또는 다른 db index)를 주면 완전히 분리됩니다(30/30, 20/20). v4는 Redis 7.0 이상(7.2 권장) 또는 Valkey 8 이상이 필요하고, chart 1.5.41의 Valkey 8.0.2가 해당됩니다. |
| 5 | 오브젝트 스토리지 | 버킷 하나, 새 파일은 prefix를 나눔(`v4/events/`, `v4/media/`). media 행은 자기 버킷과 경로를 갖고 있어서 Postgres dump로 옮긴 v3 첨부 파일을 v4가 그대로 내줍니다(sha256 일치). v4가 v3 시절 event 파일도 지울 수 있도록 `blob_storage_file_log`도 복사합니다. |
| 6 | 비밀 값 | `SALT`, `ENCRYPTION_KEY`, `NEXTAUTH_SECRET`이 같으면(두 release가 같은 Secret을 읽음) v3의 API 키, v3 세션 쿠키, v3가 암호화한 LLM 키가 모두 v4에서 동작합니다. 다른 값으로 한 대조 실험: API 키 **401**, 세션 쿠키 거부(`user: null`), LLM 키 복호화 실패(`Unsupported state or unable to authenticate data`, mock 모델에 아무것도 도달하지 않음). |
| 7 | 전환 | 수집 전환 = Service selector 변경 한 번: **요청 396개 중 실패 0**, v3의 마지막 trace 07:18:38, v4의 첫 trace 07:18:39(트래픽 간격 1초). 읽기 공백(v3의 마지막 몇 분이 아직 v4에 안 보이는 시간): **187초**(마지막 델타 복사 1.6초 + 이번 달 파티션 backfill 재실행 173초). 유실 확인: 받아들여진 trace **396/396**이 v4에 있음(v3 경유 195, v4 직접 201), v3의 trace·observation·score 중 빠진 것 0. 롤백 리허설: 30초 동안 v3로 되돌렸다가 다시 v4로, 260개 중 실패 0, 그 사이 v3가 받은 29개는 이후 복사. v4는 OTel SDK를 받습니다(Python SDK 3.15.0과 4.17.0, 각각 5/5). legacy `/api/public/ingestion`은 trace에 207과 이벤트별 400(`Event type not accepted`, score만 받음)을 돌려줍니다. |

### 경로

위 English 절의 그림과 같습니다.

### 고정 버전 (2026-11-18 확인)

위 English 절의 표와 같습니다.

### 사전 준비물

kind 노드에 쓸 여유 메모리 약 10 GB가 있는 Docker, `kind`, `kubectl`, `helm` 3.17 이상, `jq`, `openssl`,
Python 3.10 이상(기본 `PYTHON=python3.12`). 화면 캡처(`shots.sh`)를 하려면 Playwright가 있어야 합니다
(`PLAYWRIGHT_DIR=<node_modules/playwright가 있는 디렉터리>`).

### 단계

이 디렉터리에서 순서대로 실행합니다. 각 단계는 스스로 결과를 확인하고 FAIL이 있으면 0이 아닌 값으로 끝납니다.

| 단계 | 하는 일 | 답하는 질문 |
|---|---|---|
| `01-cluster.sh` | kind 클러스터, 두 release가 함께 읽는 앱 Secret, SDK 가상환경 | — |
| `02-data-layer.sh` | `data-layer.yaml`: Keeper가 있는 replica 1개짜리 클러스터 `default`의 ClickHouse 25.2.1, Postgres 17.3, Valkey 8.0.2, MinIO | — |
| `03-install-v3.sh` | `lf-v3`: chart 1.5.41, Langfuse 3.172.1, 저장소는 모두 외부(`values/v3.yaml`); 클라이언트용 Service `langfuse-app`, mock LLM, curl pod(`helpers.yaml`) | — |
| `04-seed-v3.sh` | prompt, dataset과 experiment run, score가 달린 SDK v3 trace 40개, legacy API trace 10개, media 첨부 하나, LLM 연결 하나 | — |
| `05-ch-upgrade.sh` | 트래픽을 받는 중에 ClickHouse를 그 자리에서 26.8.39.19로, timestamp 설정 포함(`CH_DATETIME_FIX=0`이면 실패를 재현); v3 수집·조회 확인 | 1 |
| `06-v4-release.sh` | Postgres (b), `CREATE DATABASE langfuse_v4`, `lf-v4`(`values/v4.yaml`, 바꾸는 값은 ConfigMap `lf-v4-env`); v3 API 키, 세션 쿠키, LLM 키, media를 v4에서 | 2, 3, 5, 6 |
| `07-copy-and-backfill.sh` | `copy-ch.sh initial` 다음 v4의 historic backfill; v3와 v4 개수 비교, 예전 trace를 v4 API와 UI로 | 2 |
| `08-pg-new-instance.sh` | Postgres (a): `pg-new.yaml`, 인스턴스 사이 dump → restore, v4를 그 위로, 다시 (b)로 | 3 |
| `09-pg-shared.sh` | 임시 쌍 `lf-v3c`/`lf-v4c`: Postgres (c), key prefix 유무에 따른 Redis, 다른 비밀 값 | 3, 4, 6 |
| `10-cutover.sh` | 델타 복사, 마지막 Postgres 복사, 전환, drain, 마지막 델타, 유실 확인, 롤백 리허설, SDK 확인, v3를 0으로 | 7 |
| `99-cleanup.sh` | 클러스터와 `.work/` 삭제 | — |
| `copy-ch.sh`, `rebackfill.sh`, `traffic.sh`, `inventory.sh`, `produce.py`, `ui.py`, `shots.sh` | 단계들이 부르는 도구 | — |

### 결과 (2026-11-18)

확인한 버전: Langfuse v3.172.1 → v4.82.0 / SDK 3.15.0, 4.17.0 / CH 25.2.1.3085 → 26.8.39.19 /
PG 17.3(방식 (a): 17.12) / Valkey 8.0.2 / MinIO 2024.12.18, chart 1.5.41과 2.2.5, kind 0.33.0
(Kubernetes 1.37.0, 노드 1개), Helm 4.3.1, Docker 29.9.3(VM 12 CPU, 15.6 GiB), Apple M4 Pro.
01~10단계를 새 클러스터에서 처음부터 끝까지 실행했습니다(로그는 [results/](results/)). 08은 첫 시도에서 Postgres 초기화
경합으로 멈춰서(스크립트에서 수정) 09 다음에 다시 실행했습니다. 08과 09는 서로 독립적입니다. 데이터는 trace 수백 건이므로
시간은 동작 방식을 보여 줄 뿐 용량 산정용이 아닙니다. 실행 뒤 로그에서 실습용 Postgres 비밀번호, 공개 키 하나, 호스트 경로를 가렸고,
06과 09에서 그것을 출력하던 두 줄을 그에 맞게 바꿨습니다. 그 밖에는 바꾸지 않았습니다.

| 단계 | 결과 |
|---|---|
| 03 v3 | chart 1.5.41 설치 77초(+ worker 재시작, 발견 2); ClickHouse schema 34, Prisma migration 391개 |
| 04 seed | trace 55, observation 134, score 40, dataset run item 4, media 파일 1, LLM 연결 1; background migration 10/10 완료 |
| 05 ClickHouse | 25.2.1.3085 → 26.8.39.19: rollout 32.9초, `/ping` 실패 33초(그중 이미지 pull 25.8초, 이미지가 캐시에 있던 첫 실행은 8초). 그 사이 보낸 트래픽 trace 107/107 저장; worker는 `ECONNREFUSED` 192번, timeout 57번을 기록하고 재시도. 이후: schema 34 그대로, dirty 아님; 2200년 이후 행 0; 새 trace 15/15; v3 traces, observations, scores, sessions, daily metrics API 200. 설정 없이(첫 실행): 업그레이드 구간부터 쓴 trace 98개 중 83개가 9999-12-31 |
| 06 v4 | Postgres (b) dump+restore 0.6초(455 KB); `lf-v4` 설치 64.7초; `langfuse_v4`에 ClickHouse schema 56; Prisma migration 94개; 예전 Postgres 테이블 삭제됨; 설치 경합으로 background migration 1개 실패, 초기화 뒤 완료. v3 키 200(틀린 secret 401), v3 세션 쿠키 통과(변조하면 거부), v3가 암호화한 LLM 키 복호화(mock이 `sk-mock-sbs-lab-0001` 받음), v3 media를 sha256 일치로 제공 |
| 07 복사 + backfill | 766행 3.5초; backfill 1~4단계 193.1초; v3 trace 177 / observation 276 / score 50, v4 trace 177개, 빠진 trace 0·observation 0, virtual root 177; 예전 trace: observation 4개(virtual root + SDK root + 2), score, experiment, prompt, dataset이 v4 API에; 같은 trace가 v4 UI에([results/v4-v3-trace.png](results/v4-v3-trace.png), v3 화면: [results/v3-v3-trace.png](results/v3-v3-trace.png)) |
| 08 Postgres (a) | 인스턴스 사이 dump → restore 0.7초; migration 94개 포함 v4 재시작 26.9초; 키, prompt, 예전 trace 정상; (b)로 복귀 26.9초 |
| 09 Postgres (c) | v3c가 쓰는 데이터베이스에 migration 94개를 적용한 v4c 설치 47.5초; 그동안 v3c 확인 60/60 200; v3c 읽기·쓰기 7/7 PASS; v3c에서 만든 키가 v4c에서 동작; v3c 재시작 정상; v3c worker `Cannot find module './createRootSpansFromTraces'` |
| 09 Redis | prefix 없음: v3c로 30개 → v3c 8, v4c 0, 없어짐 22; v4c로 20개 → v4c 20. `REDIS_KEY_PREFIX=lf-v4c`: 30/30, 20/20, 넘어간 것 0 |
| 09 다른 비밀 값 | API 키 401; v3 세션 쿠키 `user: null`; LLM 키 `Unsupported state or unable to authenticate data` |
| 10 전환 | v3 운영 중 델타: trace 20개, backfill 재실행 143초; 마지막 Postgres 복사 1.1초 + v4 재시작 29초; 전환: 396개 중 실패 0, v3 → v4 1초 이내; 0.2초 뒤 v3 queue 비어 있음; 마지막 델타 trace 175개, backfill 재실행 173초, 읽기 공백 187초; v4에 396/396, 빠진 것 0; v3로 30초 롤백(trace 29개), 다시 v4로, backfill 재실행 202초, v4에 260/260; SDK 3.15.0과 4.17.0 수용, legacy trace-create 400; v1 `traces`, `observations`, `metrics/daily` 404, `v2/observations`, `v3/scores` 200; v3를 0으로, health 4.82.0. 시간 기록: [results/cutover-timeline.txt](results/cutover-timeline.txt); 최종 상태: [results/final-checks.txt](results/final-checks.txt) |

### 전환 절차

`10`에서 측정했습니다(시각은 [results/cutover-timeline.txt](results/cutover-timeline.txt)). 그 전에 `06`~`07`이 v3가 서비스하는
동안 초기 복사를 했고(Postgres dump 0.6초, v4 설치 65초, ClickHouse 복사 3.5초, backfill 193초) 그 위에서 v4를 확인했습니다.

1. **v3 운영 중 델타** — `copy-ch.sh delta`(저장한 watermark 이후 `event_ts`의 행), 이어서 그 행이 속한 파티션에
   `rebackfill.sh <yyyymm>`. trace 20개: 복사 2.6초, backfill 재실행 143초. 델타가 작아질 때까지 반복하지만, backfill
   재실행 시간 아래로는 줄지 않습니다(발견 5).
2. **마지막 Postgres 복사** — v3 데이터베이스를 새 데이터베이스로 dump(1.1초), backfill gate를 끈 채 v4를 거기에 연결하고,
   backfill chain을 완료로 표시하고, gate를 켭니다(29초). v4는 아직 서비스하지 않으므로 클라이언트에는 보이지 않습니다.
   이 시점부터 v3 UI에서 바꾼 것(prompt, dataset, 키)은 넘어가지 않으니 몇 분 동안 멈춥니다.
3. **전환** — 클라이언트 endpoint(여기서는 Service `langfuse-app`)를 v4 web으로 옮깁니다. 요청 396개 중 실패 0, v3가 받은
   마지막 trace와 v4가 받은 첫 trace 사이 1초.
4. **v3 drain** — v3의 BullMQ `wait`/`active` 목록이 빌 때까지(여기서는 0.2초) 기다리고, ClickHouse 쓰기 간격(10초)만큼 더.
5. **마지막 델타** — `copy-ch.sh delta`(trace 175개, 1.6초)와 `rebackfill.sh`(173초). 끝날 때까지 전환 직전 몇 분의 trace는
   v4 데이터베이스에 있지만 아직 보이지 않습니다. 이것이 읽기 공백이고 전환부터 187초.
6. **유실 확인** — 받아들여진 trace id가 모두 `events_full`에 있음(396/396), v3의 trace·observation·score가 모두 v4에 있음(빠진 것 0).
7. **필요하면 롤백** — endpoint를 v3로 되돌립니다(v3 데이터베이스는 그대로; 리허설에서 30초 동안 v3로 실패 0). 그 사이 v4가
   받은 것은 v3에 없습니다. 다시 앞으로 = 되돌린 뒤 롤백 구간에 델타와 backfill 재실행(trace 29개, 202초; v4에 260/260).
8. **v3 내리기** — web과 worker를 0으로 줄이고 release와 `default`, `langfuse`는 한동안 남겨 둡니다. 3.225.7 미만 v3가 더
   이상 쓰지 않으면 ClickHouse timestamp 설정을 뺍니다. 나중에 지웁니다.

### Postgres는 어느 방식으로

| 방식 | 방법 | 측정 | 판단 |
|---|---|---|---|
| (a) 새 인스턴스 | v3 서버의 `pg_dump -Fc`를 새 서버(17.12)의 `pg_restore`로 바로 넘김 | dump+restore 0.7초; migration 94개 포함 v4 재시작 27초; API 키, prompt, 예전 trace 정상 | 동작함. 서버도 바꿔야 할 때(메이저 버전, 크기, 관리형 서비스) 선택 |
| (b) 같은 서버, 새 데이터베이스 | `CREATE DATABASE langfuse_v4`, `pg_dump | pg_restore` | dump+restore 0.6초(dump 455 KB); v4 설치 64.7초 | **권장**: 새 서버가 필요 없고 v3 데이터베이스는 그대로(롤백 = 클라이언트를 되돌리기), 전환 때 dump를 한 번 더 |
| (c) 데이터베이스 공유 | v3 데이터베이스에 v4를 연결 | migration 94개 동안과 그 뒤에도 v3가 계속 응답 | 이 데이터에서는 동작하지만 v3 worker가 v4 행에서 오류(발견 7), v4의 모든 변경이 v3의 유일한 데이터베이스에 적용되고, 롤백하려면 백업 복원 |

(b)를 고르는 이유: side-by-side의 가치는 v3를 끌 때까지 v3가 손대지 않은 사본을 갖고 있다는 데 있습니다.
(c)는 Postgres에서 그것을 포기하는데, Postgres는 두 사본 중 싼 쪽입니다(여기서는 수백 KB에 수 초; Postgres에는
trace가 아니라 메타데이터가 있음). 그 사이 사용자가 v3에서 바꾼 것을 v4가 받도록 전환 때 dump를 다시 합니다
(`10`, 2단계). v4는 PG 15 이상(16 권장, [postgres.mdx](https://github.com/langfuse/langfuse-docs/blob/aabc0c6d9c309db6efda220d06aa05967d6c5ff6/content/self-hosting/deployment/infrastructure/postgres.mdx))이 필요하고,
chart 1.5.41의 17.3이 해당됩니다.

3.172.1(391개 적용)과 4.82.0(485개) 사이 Prisma migration 94개 중 데이터나 스키마를 지우는 것은
`20260723124010_drop_dataset_run_items_table`과 `20260723150000_drop_legacy_tracing_tables`(Postgres
`dataset_run_items`, `traces`, `observations`, `scores`와 그 테이블을 비운 background migration 행),
`20261109110453`(`20261109110421`이 대체 인덱스를 만든 뒤 `annotation_queue_items` 인덱스 하나 삭제), 그리고 v4에만
있는 테이블(`monitors`, `slack_integrations`의 pending 컬럼, `gateway_ai_connections`, `verified_domains`)의 컬럼·인덱스
삭제입니다. 3.172.1은 지워지는 테이블을 실행 중에 읽지 않습니다(소스 grep, 09의 (c)에서도 계속 동작).
`20260821121500_backfill_evaluator_v2`, `20260924213400_backfill_role_assignments`,
`20261022120000_backfill_user_role_assignments`는 v3 행을 새 테이블로 한 번 복사합니다.

### 발견한 것

1. **ClickHouse 26.8은 3.225.7 이전 Langfuse v3의 timestamp를 망가뜨립니다.** 26.8에서
   `input_format_read_datetime_number_as_raw_value`의 기본값이 1에서 0으로 바뀌었습니다(`system.settings_changes`).
   해당 v3 release는 `DateTime64(3)` 값을 따옴표 없는 밀리초 정수로 보내는데 26.8은 이를 초로 읽어서
   `created_at`, `updated_at`, `event_ts`(observation의 `start_time`/`end_time`도)가 1000배로 저장되고
   `9999-12-31 23:59:59`로 보입니다. 첫 실행에서 업그레이드 구간부터 v3.172.1이 쓴 trace 98개 중 83개(observation 103개)가
   해당됐습니다([results/first-run-datetime.txt](results/first-run-datetime.txt)). upstream:
   [langfuse#16858](https://github.com/langfuse/langfuse/issues/16858), 3.225.7에서 수정
   ([#16957](https://github.com/langfuse/langfuse/pull/16957)). 업그레이드 가이드는 v3 release가 "현재 ClickHouse 버전과
   완전히 호환된다"고 하지만 ClickHouse 26.8 이상의 v3 < 3.225.7에는 맞지 않습니다. 여기서 쓴 해결책: 이 설정을 1로
   하는 `users.d` profile을 새 이미지와 같은 rollout으로 mount해서(`05-ch-upgrade.sh`) 26.8의 첫 쿼리부터 적용되게 합니다.
   그 profile의 모든 사용자에 적용되는데, v4.82.0은 이 설정 아래에서도 잘못된 행을 쓰지 않았습니다(문자열로 보냄).
   이미 쓰인 행은 복구할 수 있습니다(저장된 값이 잘린 것이 아니라 1000배): `copy-ch.sh`가 v4로 복사하면서 2200년 이후
   값을 1000으로 나눕니다. v3 자신의 테이블에서는 그대로 남습니다(timestamp가 정렬 키에 있어서 `ALTER … UPDATE`로 못 고침).
2. **v4 첫 설치: 경합 때문에 background migration 하나가 영구히 실패합니다.** helm은 web과 worker를 함께 띄웁니다.
   web은 Prisma migration 다음 ClickHouse migration을 돌리는데 worker는 이미 background migration을 돌리고 있어서,
   `20261110_backfill_audit_logs_to_clickhouse`가 web이 그 테이블을 만들기 22초 전에 `ClickHouse audit_logs table does not exist`로
   실패했습니다(두 실행 모두). 실패한 행은 다시 시도되지 않습니다. `06`이 `failed_at`을 지우고 worker를 재시작합니다.
   in-place 실습의 발견 2와 같은 종류입니다: v3 첫 설치에서도 worker가 Prisma 테이블보다 먼저 떠서
   (`The table public.background_migrations does not exist`) 재시작할 때까지 아무것도 돌리지 않았습니다.
3. **v4 데이터베이스는 v4보다 먼저 있어야 합니다.** `clickhouse/scripts/up.sh`는 golang-migrate에
   `database=${CLICKHOUSE_DB}`를 넘길 뿐 만들지 않습니다. 문서의 v4 grant는 `default.*`와
   `default.observations_pid_tid_sorting` 기준이라 데이터베이스를 따로 두면 `langfuse_v4.*`에 줘야 합니다(제한된 사용자로는
   확인하지 않음: 실습 사용자는 전체 권한).
4. **backfill을 다시 돌리면 merge 전까지 모든 행이 두 번 보입니다.** backfill은 파티션을 골라 다시 돌릴 수 있고
   (`args.partitions`), 여기서는 델타를 그렇게 `events_full`로 보냅니다. 파티션 전체를 다시 쓰는데,
   `events_full`/`events_core`는 ReplacingMergeTree지만 `/api/public/v2/observations`는 중복을 제거하지 않아서
   첫 실행에서 trace 하나의 observation이 4개가 아니라 7개로 나왔습니다(`OPTIMIZE … PARTITION … FINAL` 전까지).
   `rebackfill.sh`가 이어서 그것을 실행합니다. 가이드의 "재실행은 중복 제거된다"는 merge 뒤에만 맞습니다.
5. **backfill은 chunk마다 고정 비용이 있습니다.** chunk마다 쿼리가 실행 중인지 확인할 때까지 기다리고 30초마다
   확인합니다(`pollIntervalMs`, 행의 `args`로 바꿀 수 있음): 파티션 하나의 trace 177개에 1~4단계가 193초 걸렸습니다.
   `rebackfill.sh`는 2초로 두고, 그러면 델타는 델타 재실행 세 번이 143, 173, 202초 걸렸습니다. 델타 크기가 아니라 파티션·part 수에 비례하므로
   읽기 공백은 이번 달 파티션 크기로 잡아야 합니다.
6. **salt는 같아야 하고, bcrypt 대체 경로는 바뀐 salt를 덮지 못합니다.** v4.82.0은 API 키를 `sha256(secret + SALT)`로 찾고,
   bcrypt 확인은 fast hash가 아직 없는 키에만 합니다(`web/src/features/apiKey/verifier.ts`). 다른 salt에서 v3 키는 **401**이었습니다(09).
7. **Postgres 공유 (c): v3.172.1 worker가 v4의 background migration 행에 걸립니다.** 3.172.1의 manager에는 `envGate`
   필터가 없어서 v4의 gate가 걸린 `20260701_v4_step_*` 행을 집어 들고 매번 `Cannot find module './createRootSpansFromTraces'`로
   실패합니다. 이후 v3 background migration이 있다면 그 뒤에 막힙니다. 나머지는 이 데이터에서 문제가 없었습니다:
   v4의 migration 94개 동안 v3.172.1이 응답했고(health와 prompt 확인 60/60 200), 깨끗하게 재시작했고(`No pending migrations to apply`),
   prompt, dataset item, API 키를 읽고 썼고, v3 UI 호출(tRPC) 여섯 개가 200이었습니다(`evals.allConfigs`는 실습의 요청 형식 때문에
   400, 더 보지 않음). migration 뒤 v3에서 만든 API 키에는 `role_assignments` 행이 없는데, v4.82.0이 처음 쓸 때 만듭니다
   (`backfillRoleAssignments`, deprecated 표시, "다음 메이저 버전에서 제거").
8. **두 release가 Redis keyspace 하나를 쓰면 데이터를 잃습니다.** 둘 다 같은 BullMQ queue 이름을 씁니다. prefix 없이 두면
   v4 worker가 v3의 ingestion job을 가져갑니다. v3로 보낸 trace 30개(SDK v3 20개, legacy API 10개) 중 v3가 저장한 것은
   8개, 22개는 어디에도 없었습니다(최종 실행). 첫 실행에서는 v3 6개, v4가 자기 데이터베이스에 20개, 없어진 것 4개였습니다.
   어디로 가는지는 달라도 v3를 떠난다는 점은 같습니다. key 목록에 두 release가 같은 `bull:<queue>` 키를 쓰는 것이 보입니다(09).
   v4에 `REDIS_KEY_PREFIX`(cluster 모드에서도 hash tag로 동작)나 다른 db index를 주면 사라집니다: 30/30, 20/20, 넘어간 것 0.
9. **v3 테이블이 모두 v4에 있는 것은 아닙니다.** `event_log`, `project_environments`, 예전 `dataset_run_items`는 in-place
   업그레이드에서 v4 migration이 지우는 테이블이고, 새 v4 데이터베이스에는 처음부터 없으므로 복사하지 않습니다.
   복사한 다섯 테이블은 v4 스키마에 모든 컬럼이 있습니다(잃는 컬럼 없음).
10. **"먼저 최신 v3로" 전제 조건이 v4로 옮겨 갑니다.** 가이드는 v4 전에 최신 v3와 모든 background migration 완료를 요구합니다.
    v4 migration이 그 migration들이 비운 Postgres 테이블을 지우기 때문입니다. 3.172.1은 자기 것(10행)을 모두 끝냈고,
    3.172.1에 없는 후기 v3 migration(`20261022_encrypt_legacy_webhook_headers`, `20261110_backfill_audit_logs_to_clickhouse`)은
    v4가 자기 데이터베이스에 추가해서 실행했습니다.

### 공식 절차가 가정하는 것과 이 실습이 바꾼 것

- **업그레이드 가이드**는 배포 하나를 그 자리에서 올립니다: 같은 `CLICKHOUSE_DB`, 같은 Postgres 데이터베이스, 쓰기 모드
  `legacy` → `dual` → backfill → `events_only`. backfill은 v4가 쓰는 데이터베이스의 예전 테이블을 읽습니다. 여기서는 v4가 예전
  테이블에 쓰지 않습니다. 예전 테이블은 v3에서 복사한 것만 받고 backfill이 그것을 변환하며, v4는 처음부터 `events_only`로 돕니다.
  `dual`과 `legacy`는 쓰지 않습니다.
- **가이드의 gate**(최신 v3, 모든 background migration 완료)는 v3.172.1 자신의 migration으로 확인합니다(발견 10).
- **가이드의 롤백**(ClickHouse 스키마를 37로 되감고 최신 v3로)은 필요 없습니다: v4는 v3의 데이터베이스를 건드리지 않습니다.
  롤백 = 클라이언트 endpoint를 v3로 되돌리고, 그 사이 v4가 받은 것을 복사하는 것인데 그 복사를 해 주는 도구는 없습니다(v4는
  `events_full`에 쓰고 v3는 `traces`를 읽음).
- **backfill**은 초기 복사에 한 번 돌리고, 델타마다 건드린 파티션에 대해 다시 돌립니다(`rebackfill.sh`, 발견 4와 5). chain 행은
  SQL로 초기화합니다.
- **마지막 Postgres 복사**는 v4 backfill 행을 미완료 상태로 다시 가져옵니다. `10`은 그 행을 완료로 표시하고(결과는 이미
  `langfuse_v4`에 있음) 델타만 다시 돌립니다.

### 여기서 확인하지 않은 것

- 문서의 grant만 가진 ClickHouse 사용자; replica가 둘 이상인 ClickHouse(여기는 Keeper가 있는 1 shard × 1 replica);
  Redis cluster나 Sentinel; 관리형 서비스(RDS, ElastiCache, S3).
- 수백 건을 넘는 데이터와 이번 달 외의 파티션: 시간은 동작 방식이지 용량 산정이 아닙니다.
- 초기 복사 뒤 v3에서 한 삭제(지운 trace는 v4에 남음), evaluator와 export, 마지막 Postgres 복사 뒤 v3에 쓴 annotation queue와 comment.
- Python SDK v2, JS/TS SDK: 이들이 부르는 legacy REST 호출만 보냈습니다(trace는 거부).
- `lf-v3` 자체의 Helm 업그레이드(chart 1.5.41에 그대로), Ingress/DNS: endpoint 전환은 Service selector이고, 운영의 DNS나 load
  balancer 변경에는 자체 TTL이 있습니다.
- 롤백 뒤 v4에서 v3로의 역복사.
