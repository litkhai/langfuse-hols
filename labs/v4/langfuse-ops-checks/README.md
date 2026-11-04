# Langfuse v4 operations checks: blob-storage call rate, sizing, collection loss, per-database separation, audit log

[English](#english) | [한국어](#한국어)

---

## English

Five gap tests for a self-hosted Langfuse v4 review (context: a regulated financial deployment), run on the shared v4 stack (`_base/`, Docker Compose, single node) on **2026-11-04**. Tests 01–04 ran on **Langfuse v4.56.0 / SDK 4.17.0 / CH 26.8.22.13** (`events_only`, existing volumes, OSS mode except where noted); test 05 ran on **Langfuse v4.75.0** (latest v4 release, published 2026-11-04 09:26 UTC) with the EE overlay on fresh volumes. Docker 29.9.2, Compose v5.6.1, Python 3.12.14, opentelemetry-exporter-otlp-proto-http 1.45.0, Helm 4.3.1 (render only, chart langfuse 2.2.1). No cloud resources, no model calls. Every fact below names the file it was read from in the images; every number names its run. Raw results: [`results/`](results/).

**Laptop, not a cluster.** One Docker Desktop VM (12 CPUs, 16 GiB) on one laptop, load generator on the same host. From test 02 on, containers of other projects were running on the same VM (recorded per step); timings are ratios between set-ups, not capacity promises.

### The short answer

| Question | Answer (measured on this stack unless marked "source") |
|---|---|
| What sets the blob-storage (S3) call rate? | **One PutObject (web) + one GetObject (worker) per OTLP POST.** 4,020 traces/min sent one trace per POST: 67 PUT/s; ten traces per POST: 6.7 PUT/s; 67 per POST: 1 PUT/s. No server variable changed the count (four variants tried). |
| Which knob reduces blob calls then? | Client-side batching only: the SDK's `flush_at` / `flush_interval` (`LANGFUSE_FLUSH_AT`, default 512 spans; `LANGFUSE_FLUSH_INTERVAL`, default 5 s) or an OpenTelemetry Collector batch processor in front of Langfuse. |
| And ClickHouse inserts? | One insert into `events_full` per `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS` (default 1000 ms) per worker: 1/s at the defaults, 0.2/s at 5000 ms. |
| What is `LANGFUSE_TRACE_BATCH_*`? | (source) Not an ingestion batcher. It schedules whole-trace batches for Topics summaries and runs only when `NEXT_PUBLIC_LANGFUSE_CLOUD_REGION` is set (Langfuse Cloud). Turned on here: no change. |
| Sizing vs a 4,000 requests/min baseline | On this laptop one web + one worker at 2 CPUs each sustained **4,000 traces/min** (4 × 11 KB observations, ~2.9 MB/s of OTLP JSON) with lag p95 1.6–1.9 s in the three runs without foreign load, and failed at 8,000. **Web was the bottleneck** (~2 CPUs busy), the worker used ~0.3–0.6 CPU; a second worker did not raise the limit. Proposed tiers below, with `values-base.yaml` as the large one. |
| Does every observation arrive when a component dies? | **No — but nothing accepted is lost for good.** 20 s SIGKILL each, 12,000 observations sent: worker −4, web −1,596 (client gave up), ClickHouse −1,972, Redis −8, MinIO −1,524 (client got 500). Every server-side loss (worker, ClickHouse, Redis) was still in blob storage and was re-processed to 12,000 / 12,000 with [`03c-reconcile.sh`](03c-reconcile.sh). Client-side losses (web down, MinIO down) never reached Langfuse. |
| What does the Python SDK do on 5xx? | Retries 429 / 502 / 503 / 504 and connection errors with backoff 1, 2, 4, 8, 16 s, at most 6 attempts, **within `LANGFUSE_TIMEOUT` (default 5 s)** — so 3 attempts in ~3 s by default. A **500 is not retried**: the batch is dropped. |
| One ClickHouse server, one database per instance? | **Works.** `CLICKHOUSE_DB` is honoured by migrations, ingest and reads; user A gets `ACCESS_DENIED` on B's database and sees only its own in `SHOW DATABASES`. The database must exist first. Outside its database Langfuse reads `system.parts` and `system.query_log` (background jobs); without grants those jobs fail, ingest and reads do not. Granting `system.query_log` shows every user's queries. |
| What lands in the audit log on v4.75.0? | Postgres `audit_logs`: prompt create / update / delete, API key create / delete, org membership create / update / delete, project membership create, project delete, batch export create. **Not**: project create / update, any read. Reads are recorded only with `LANGFUSE_AUDIT_LOG_ACCESS_EVENTS=enforced` (or an org opt-in) and only for the UI trace detail (`events.byTraceId`); `GET /api/public/traces/{id}` answers 404 in `events_only`. The ClickHouse `audit_logs` table stays **empty** on self-hosted: its relay runs only on Langfuse Cloud. |

### Files

| File | Does |
|---|---|
| [lib.sh](lib.sh) | Shared helpers: `ops_compose` (base stack + this lab's overlays), `ops_apply` / `ops_restore`, `ch`, `s3_counts` (MinIO request counters), `run_load` (load → settle → measure) |
| [loadgen.py](loadgen.py) | Reusable open-loop OTLP/HTTP generator: `--rpm` (traces/min), `--obs`, `--prompt-bytes`, `--output-bytes`, `--traces-per-post`, `--read-ratio`, `--retry-deadline` (SDK retry rule). Synthetic payloads, run id as trace tag and metadata. Stdlib only |
| [01-batching.sh](01-batching.sh) | Test 01: six scenarios at 4,020 traces/min, S3 PUT/GET and ClickHouse inserts each |
| [02-sizing.sh](02-sizing.sh) | Test 02: rate ladder for one worker, one worker at 2 CPUs, two workers at 2 CPUs, plus a read-mix step |
| [03-failures.sh](03-failures.sh) | Test 03: kill worker, web, ClickHouse, Redis, MinIO one at a time under tagged load |
| [03b-sdk-retry.py](03b-sdk-retry.py) | Test 03: the SDK exporter against a scripted 5xx server (no Langfuse needed) |
| [03c-reconcile.sh](03c-reconcile.sh), [requeue-otel.js](requeue-otel.js) | Test 03: blob files vs `events_full` rows per run; `--replay` puts short files back on the OTel queue |
| [04-db-separation.sh](04-db-separation.sh) | Test 04: instances A and B on one ClickHouse, one database and one user each |
| [05-audit-log.sh](05-audit-log.sh) | Test 05: CRUD and reads on the latest v4 with EE, then Postgres and ClickHouse audit tables |
| [99-restore.sh](99-restore.sh) | Back to the normal OSS stack after an interrupted run |
| `docker-compose.{knobs,cpu2,worker2,cpu2w2,dbsep,audit}.yml` | Overlays on `_base/docker-compose.yml` (same project `langfuse-hols-v4`) |
| [clickhouse-users-dbsep.xml](clickhouse-users-dbsep.xml) | Test 04's ClickHouse users (`users.d/`, removed afterwards) |
| [values-ingest.yaml](values-ingest.yaml) | Test 01's knobs as Helm values for chart 2.2.1, layered on `labs/v4/langfuse-k8s/values-base.yaml` |

### Run

```bash
_base/bin/up.sh v4                                   # OSS stack; every script ends on it again
cd labs/v4/langfuse-ops-checks
./01-batching.sh            # ~10 min
./02-sizing.sh              # ~30 min; LADDER="2000 4000 …" SECS=60 READ_RATIO=0.1
./03-failures.sh            # ~20 min; OUTAGE=20 RETRY_DEADLINE=5; or ./03-failures.sh clickhouse
.venv-v4/bin/python 03b-sdk-retry.py                 # from the repository root: ../../../.venv-v4/bin/python
./03c-reconcile.sh --replay
./04-db-separation.sh       # ~5 min; CLEANUP=0 keeps A and B running
./05-audit-log.sh 4.75.0    # ~6 min; own project and volumes, stack stopped meanwhile
./99-restore.sh             # only after an interrupted run
```

`PY=<python>` picks the interpreter for `loadgen.py` (stdlib only; default `.venv-v4/bin/python`, else `python3`). Run one script at a time: they recreate the stack's web and worker.

### 01 — Worker batching and blob-storage call rate

**Where the calls come from (source, 4.56.0).** The OTLP route of web calls `OtelIngestionProcessor.publishToOtelIngestionQueue` once per request; it writes the request's `resourceSpans` as one object `events/otel/<project>/<yyyy>/<mm>/<dd>/<hh>/<mi>/<uuid>.json` (`uploadJson`) and enqueues one `otel-ingestion-job` (`@langfuse/shared/dist/src/server/otel/OtelIngestionProcessor.js:177-186`). The worker downloads that object once per job (`/app/worker/dist/queues/otelIngestionQueue.js:336`) and, in `events_only`, writes each observation to `events_full` through `ClickhouseWriter`, which flushes per table when `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_BATCH_SIZE` rows are queued or every `…_WRITE_INTERVAL_MS` (`/app/worker/dist/services/ClickhouseWriter/index.js:36-37, 87`). An S3 `SlowDown` on upload turns into **503 with `Retry-After: 2`**, which SDKs retry (`@langfuse/shared/dist/src/server/services/s3ThrottleError.js`); any other upload error is a 500.

**Variables and their defaults** (worker: `/app/worker/dist/env.js`; shared by web and worker: `@langfuse/shared/dist/src/env.js`; both in the 4.56.0 images):

| Variable | Default | Where | What it changes |
|---|---|---|---|
| `LANGFUSE_OTEL_INGESTION_QUEUE_PROCESSING_CONCURRENCY` | 5 | worker env.js:101 | OTel jobs in parallel per worker |
| `LANGFUSE_OTEL_INGESTION_SECONDARY_QUEUE_PROCESSING_CONCURRENCY` | 1 | worker env.js:105 | same, secondary queue (`LANGFUSE_SECONDARY_OTEL_INGESTION_QUEUE_ENABLED_PROJECT_IDS`) |
| `LANGFUSE_INGESTION_QUEUE_PROCESSING_CONCURRENCY` / `…_SECONDARY_…` | 20 / 5 | worker env.js:205, 209 | legacy `/api/public/ingestion` jobs |
| `LANGFUSE_OTEL_INGESTION_QUEUE_SHARD_COUNT`, `LANGFUSE_INGESTION_QUEUE_SHARD_COUNT` | 1, 1 | shared env.js:192-200 | Redis queue shards |
| `LANGFUSE_INGESTION_QUEUE_DELAY_MS` | 15000 | shared env.js:188 | delay of legacy ingestion jobs (not OTel) |
| `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_BATCH_SIZE` | 1000 | worker env.js:214 | rows per ClickHouse insert (upper bound) |
| `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS` | 1000 | worker env.js:218 | flush interval of the writer |
| `LANGFUSE_INGESTION_CLICKHOUSE_MAX_ATTEMPTS` | 3 | worker env.js:222 | writer retries before it **drops** rows (test 03) |
| `CLICKHOUSE_ASYNC_INSERT_MAX_DATA_SIZE`, `…_BUSY_TIMEOUT_MS`, `…_BUSY_TIMEOUT_MIN_MS` | unset | shared env.js:146-148 | server-side async-insert buffer (inserts run as async inserts: `AsyncInsertFlush` in `query_log`) |
| `LANGFUSE_S3_CONCURRENT_WRITES` | 50 | shared env.js:267 | sockets per S3 client (`StorageService.js:96`) |
| `LANGFUSE_S3_UPLOAD_ENABLE_BUFFERED`, `…_MAX_PART_ATTEMPTS`, `…_MAX_CONCURRENT_PARTS` | false, 3, 3 | shared env.js:268-280 | multipart uploads of exports, not events |
| `LANGFUSE_S3_RATE_ERROR_SLOWDOWN_ENABLED`, `…_TTL_SECONDS` | false, 3600 | shared env.js:357-360 | on SlowDown, route a project's legacy ingestion to the secondary queue |
| `LANGFUSE_S3_EVENT_KEY_MAX_SEGMENT_BYTES` | 2048 | shared env.js:10 | key segment length |
| `LANGFUSE_ENABLE_BLOB_STORAGE_FILE_LOG` | true | worker env.js:309 | `blob_storage_file_log` rows; none were written for OTel in `events_only` |
| `LANGFUSE_TRACE_BATCH_INGESTION_ENABLED`, `…_SAMPLING_RATE`, `…_DISPATCHER_ENABLED`, `QUEUE_CONSUMER_TRACE_BATCH_QUEUE_IS_ENABLED` | false, 0, false, false | worker env.js:112-125 | Topics trace batching, Cloud only (below) |
| `LANGFUSE_TRACE_BATCH_CONCURRENCY`, `…_MAX_THREADS`, `…_REQUEST_TIMEOUT_MS`, `…_MAX_PENDING_SUMMARY_BYTES` | 2, 2, 40000, 100 MiB | worker env.js:130-149 | 〃 |
| `LANGFUSE_TRACE_BATCH_MAX_SIZE`, `…_MAX_BATCH_EVENT_UPDATES`, `…_MAX_BATCH_SERIALIZED_BYTES`, `…_MAX_TRACE_EVENT_UPDATES`, `…_MAX_TRACE_SERIALIZED_BYTES` | 60, 1500, 64 MiB, 5000, 50 MiB | worker env.js:161-187 | 〃 |
| `LANGFUSE_TRACE_BATCH_STRATEGY`, `…_IDLE_MS`, `…_PENDING_TTL_MS`, `…_DISPATCH_INTERVAL_MS`, `…_MAX_BLOCK_SIZE`, `…_EXPERIMENT_ID`, `…_READ_ENABLED`, `…_TRANSCRIPT_METRICS_ENABLED` | project, 600000 (120000 in region `DEV`), 7200000, 30000, unset, unset, false, false | worker env.js:126-200, 801-803 | 〃 |

`LANGFUSE_TRACE_BATCH_*` is checked against `NEXT_PUBLIC_LANGFUSE_CLOUD_REGION` everywhere it acts: tracking (`features/traceBatching/traceBatching.js:492-493, 601-602`, `features/otel-ingestion/processOtelEvents.js:94-95`), the dispatcher and the queue consumer (`app.js:129-145`). The consumer summarises whole traces for Topics (`queues/traceBatchQueue.js`). On a self-hosted deployment without that variable the family does nothing.

**Measured** (2026-11-04 12:18–12:27 UTC, 4,020 traces/min = 67/s for 60 s, 4 observations of 10 KB in + 1 KB out each, one worker, each scenario on freshly recreated web and worker; counts from MinIO's `minio_s3_requests_total` and `system.query_log`, [results/01-batching.jsonl](results/01-batching.jsonl)):

| Scenario | Traces / POST | POST/s | S3 PUT (/s) | S3 GET | `events_full` inserts (/s) | Arrived / sent obs | Lag p95 |
|---|---|---|---|---|---|---|---|
| defaults | 1 | 67 | 4,020 (67) | 4,020 | 60 (1.0) | 16,080 / 16,080 | 0.09 s |
| `…_WRITE_BATCH_SIZE=10000`, `…_WRITE_INTERVAL_MS=5000` | 1 | 67 | 4,020 (67) | 4,020 | **12 (0.2)** | 16,080 / 16,080 | 0.05 s |
| `LANGFUSE_OTEL_INGESTION_QUEUE_PROCESSING_CONCURRENCY=20`, `LANGFUSE_S3_CONCURRENT_WRITES=10` | 1 | 67 | 4,020 (67) | 4,020 | 60 (1.0) | 16,080 / 16,080 | 0.03 s |
| `LANGFUSE_TRACE_BATCH_*` on (ingestion, sampling 1, max size 600, dispatcher, consumer) | 1 | 67 | 4,020 (67) | 4,020 | 60 (1.0) | 16,080 / 16,080 | 0.31 s |
| client: 10 traces per POST | 10 | 6.7 | **402 (6.7)** | 402 | 60 (1.0) | 16,080 / 16,080 | 0.26 s |
| client: 67 traces per POST | 67 | 1 | **60 (1.0)** | 60 | 58 (1.0) | 16,080 / 16,080 | 1.53 s |

- **Reduces blob calls:** fewer, larger POSTs, which is a client setting. With the Python SDK one process sends one POST per `flush_interval` (5 s) or per `flush_at` spans (512), whichever comes first, so the blob call rate is about *processes × max(1/5 s, spans per second / 512)*, not traces per second. An OpenTelemetry Collector with a `batch` processor in front of Langfuse does the same for many small processes.
- **Does not reduce blob calls:** queue concurrency, `LANGFUSE_S3_CONCURRENT_WRITES` (caps sockets, not calls), the ClickHouse writer knobs, `LANGFUSE_TRACE_BATCH_*`.
- **Reduces ClickHouse inserts:** `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS` (and `…_BATCH_SIZE` as its cap). Rows become visible up to one interval later. The lag column cannot show that: `events_full.created_at` is stamped when the worker builds the row (`IngestionService/index.js:238`), before the writer's buffer.
- `written_rows` in `query_log` sometimes counts the `events_core` materialized-view rows as well (twice the rows in the 5000 ms scenario); `events_core` had exactly the `events_full` row count in every run.
- Helm values for the official chart 2.2.1: [values-ingest.yaml](values-ingest.yaml). The keys are `langfuse.worker.pod.additionalEnv` (worker), `langfuse.web.pod.additionalEnv` (web) and `langfuse.additionalEnv` (both); there is no `langfuse.worker.additionalEnv` in 2.2.1. `LANGFUSE_S3_CONCURRENT_WRITES` has its own chart key, `s3.concurrency.writes`, which renders the variable on both deployments. Rendered with `helm template` on `values-base.yaml` + `values-kind.yaml` + `values-ingest.yaml` (`clickhouse.crdCheck=false`): each variable appears once per deployment. Not installed on a cluster.

### 02 — Load generator and sizing

**Generator.** [loadgen.py](loadgen.py) is open loop: trace *i* is due at *t0 + i · 60 / rpm* whatever the server does, so a slow server shows as lag, not as a lower rate, and `sender_behind_s` says when the generator itself fell behind (never above 0.01 s here). Parameters: `--rpm` (traces per minute, one application request = one trace), `--obs` (observations per trace), `--prompt-bytes` / `--output-bytes` (every observation; random words so ClickHouse cannot compress them away), `--traces-per-post` (client batching), `--read-ratio` (reads per trace sent, alternating a trace detail and an observations list over the public v2 API — `GET /api/public/traces/{id}` answers 404 in `events_only`), `--retry-deadline` (the SDK's retry rule, test 03). Lag = `events_full.created_at − start_time`; `created_at` is stamped by the worker before the ClickHouse writer's buffer, so visibility in the UI is up to one write interval (1 s) later.

**Runs** (2026-11-04 13:28–13:52 UTC, Langfuse 4.56.0, 4 observations of 10 KB in + 1 KB out per trace, 60 s per step, pass = lag p95 ≤ 2 s and nothing lost; [results/02-sizing.jsonl](results/02-sizing.jsonl) one trace per POST, [results/02-sizing-tpp10.jsonl](results/02-sizing-tpp10.jsonl) ten). "Other CPU" is the CPU % of containers of other projects on the same Docker VM at the start of the step; "stack CPU" was sampled once mid-step (second series only).

| Set-up | Traces/min | Traces/POST | Result | Lag p50 / p95 / max | Accept p95 | Other CPU | Stack CPU |
|---|---|---|---|---|---|---|---|
| 1 worker, no cap | 2,000 | 1 | PASS | 0.02 / 0.30 / 1.07 s | 151 ms | 113 % | — |
| 1 worker, no cap | 4,000 | 1 | PASS | 0.02 / 0.68 / 1.73 s | 627 ms | 79 % | — |
| 1 worker, no cap | 8,000 | 1 | FAIL | 6.98 / 11.87 / 12.49 s | 1,859 ms | 111 % | — |
| web + worker at 2 CPUs | 2,000 | 1 | PASS | 0.02 / 0.97 / 2.24 s | 716 ms | 125 % | — |
| web + worker at 2 CPUs | 4,000 | 1 | PASS | 0.04 / 1.57 / 2.95 s | 1,410 ms | 6 % | — |
| web + worker at 2 CPUs | 8,000 | 1 | FAIL | 19.52 / 22.66 / 23.10 s | 2,621 ms | 6 % | — |
| web + 2 workers at 2 CPUs | 2,000 | 1 | PASS | 0.02 / 0.68 / 1.50 s | 669 ms | 259 % | — |
| web + 2 workers at 2 CPUs | 4,000 | 1 | FAIL | 0.30 / 2.85 / 3.80 s | 1,799 ms | 99 % | — |
| web + worker at 2 CPUs (repeat) | 4,000 | 1 | FAIL | 0.25 / 9.82 / 10.73 s | 2,632 ms | 0 % → load came during the step | — |
| web + worker at 2 CPUs | 4,000 | 10 | FAIL | 0.70 / 7.03 / 11.97 s | 3,731 ms | 117 % | web 214, worker 39 |
| web + 2 workers at 2 CPUs | 4,000 | 10 | FAIL | 0.42 / 4.90 / 7.26 s | 4,066 ms | 680 % | web 258, workers 60 + 31 |
| web + worker at 2 CPUs | 4,000 | 10 | PASS | 0.20 / 1.80 / 2.58 s | 1,321 ms | 0 % | web 81, worker 28 |
| 〃 + 0.1 reads per trace (366 reads, read p95 1,372 ms) | 4,000 | 10 | PASS | 0.18 / 1.90 / 2.90 s | 1,443 ms | 1 % | web 28, worker 161 |

What the runs support, and what they do not:

- **4,000 traces/min is the edge of one 2-CPU web on this laptop**: it passed in all three runs without foreign load (p95 1.57, 1.80, 1.90 s) and failed in every run with ≥ 99 % foreign CPU; 8,000 failed even without foreign load. A first attempt under ~6 CPUs of foreign load failed already at 2,000 ([results/02-sizing-contended.jsonl](results/02-sizing-contended.jsonl), discarded).
- **The limit is the web's OTLP intake, not the worker.** Accept latency grows with load while the worker idles (0.3–0.6 CPU at 4,000/min); a second worker did not help. Web scale-out (two replicas behind a load balancer) was not run here.
- Ten traces per POST did not raise the limit on this run: the bytes per second are the same, and the web parses them all.
- Reads at 0.1 per trace did not change ingest lag; read p95 was 1.4 s.
- One laptop, one Docker VM, foreign load from other projects: use the **ratio** (≈ 2 web CPUs per 4,000 traces/min of ~44 KB traces; ≈ 0.5 worker CPU for the same) and size with headroom, not the absolute numbers.

**Tiers relative to 4,000 requests/min** (one request = one trace of ~4 observations and ~44 KB; ClickHouse not measured here — its column is unchanged from `values-base.yaml` for large and a hypothesis below). Every tier keeps two replicas of web and worker for availability and the documented minimum of 2 CPU / 4 GiB per container, so small and medium differ from large mainly in their HPA ceilings and ClickHouse:

| Tier | Requests/min | web | worker | ClickHouse (1 shard × 3 replicas) |
|---|---|---|---|---|
| small | ≤ 1,000 | 2 × 2 CPU / 4 GiB, no HPA | 2 × 2 CPU / 4 GiB, no HPA | 2 CPU / 8 GiB, 128 GiB each (hypothesis) |
| medium | ≤ 2,000 | 2 × 2 CPU / 4 GiB, HPA max 3 | 2 × 2 CPU / 4 GiB, HPA max 3 | 4 CPU / 16 GiB, 256 GiB each (hypothesis) |
| large = [`values-base.yaml`](../langfuse-k8s/values-base.yaml) | 4,000 with headroom | 2 × 2 CPU / 4 GiB, HPA 2–4 at 50 % | 2 × 2 CPU / 4 GiB, HPA 2–6 at 50 % | 6 CPU / 24 GiB, 512 GiB each |

At 50 % HPA target, two 2-CPU web pods carry ~2 busy CPUs — about the measured 4,000/min — before they scale; four pods reach roughly twice that. The worker side has several times the headroom the measurements ask for; it is kept at two for the in-memory loss window of test 03, not for throughput.

### 03 — Collection loss under failures

**Set-up** (2026-11-04 12:34–13:01 UTC, Langfuse 4.56.0, OSS, one worker): per component, 1,200 traces/min × 4 observations (80 observations/s) for 150 s, every trace tagged with its run id; at t = 30 s `docker kill` (SIGKILL), 20 s down, `docker start`. The generator retries like the Python SDK at its defaults (5 s deadline). Afterwards the script waits until the run's rows are unchanged for 60 s. Expected = observations the server answered 2xx for. Results: [results/03-failures.jsonl](results/03-failures.jsonl), per-run samples `results/03-<component>-samples.tsv`.

| Killed for 20 s | Sent | Accepted (2xx) | Arrived | Server loss | Client loss | Client saw | Where the raw events were meanwhile | After [03c-reconcile.sh](03c-reconcile.sh) |
|---|---|---|---|---|---|---|---|---|
| worker | 12,000 | 12,000 | 11,996 | **4** | 0 | all 200 (p99 4.5 s) | blob storage + Redis: `otel-ingestion-queue` wait 87 → 382 → 722 jobs, drained ~20 s after restart | 2 files short → requeued → **12,000** |
| web | 12,000 | 10,404 | 10,404 | 0 | **1,596** | 1,284 connection errors, 885 retries | nowhere: the POSTs never reached Langfuse | nothing to replay |
| ClickHouse | 12,000 | 12,000 | 10,028 | **1,972** | 0 | all 200 | blob storage; the worker's ClickHouse writer kept rows in memory, then logged `ClickhouseWriter: Max attempts reached, dropped N events_full record(s)` 26 times | 493 files short → requeued → **12,000** |
| Redis | 12,000 | 12,000 | 11,992 | **8** | 0 | all 200, p99 28 s (requests waited for Redis) | web held the requests; no blob writes during the outage (PutObject counter flat) | 3 files short → requeued → **12,000** |
| MinIO | 12,000 | 10,476 | 10,476 | 0 | **1,524** | 381 × **500** (not retried) | nowhere: the upload failed, the POST was rejected | nothing to replay |

- **Server-side loss is real and silent to the client.** Two causes: rows buffered in the worker's ClickHouse writer when the worker dies (worker, Redis), and rows the writer drops after `LANGFUSE_INGESTION_CLICKHOUSE_MAX_ATTEMPTS` (3) failed inserts while ClickHouse is down. The OTel job has already completed in both cases, so BullMQ does not retry it (`otel-ingestion-queue` jobs: 6 attempts, exponential 5 s backoff, `@langfuse/shared/dist/src/server/redis/otelIngestionQueue.js:48-52`; no job failed in any run). The writer's own comment: `TODO - Add to a dead letter queue in Redis rather than dropping` (`ClickhouseWriter/index.js:329`). The signals to alert on: the log line above and the metric `langfuse.queue.clickhouse_writer.rows_dropped`.
- **The raw event survives.** Every accepted POST was in blob storage, and every `events_full` row keeps its source file in `blob_storage_file_path`. [03c-reconcile.sh](03c-reconcile.sh) compares the two per run and requeues the short files with [requeue-otel.js](requeue-otel.js); all three runs went back to 12,000 distinct observations (replayed rows are deduplicated by `span_id`; `count()` showed 4 duplicate rows until merge).
- **The official replay endpoint does not work for OTel files here.** `POST /api/admin/ingestion-replay` rejects a full key `events/otel/…` with `Unsupported replay type: otel`, and queues a key without the `events/` prefix that the worker then cannot download (`NoSuchKey`), with `LANGFUSE_S3_EVENT_UPLOAD_PREFIX=events/` ([results/03c-admin-replay.txt](results/03c-admin-replay.txt)). Same `Unsupported replay type: otel` on 4.75.0 (test 05). Hence the direct requeue.
- **Client-side loss** happens when web or blob storage is down: web refuses connections, and a failed upload is answered with 500, which the SDK does not retry. The SDK's 5 s default deadline covers about 3 s of outage.
- **For 100 % collection as a KPI:** reconcile blob storage against `events_full` on a schedule (this script's logic) and alert on `rows_dropped`; raise `LANGFUSE_TIMEOUT` on the clients (30 s gave 6 attempts over ~30 s, below); run web and blob storage highly available, because their outages lose data before Langfuse has it; keep blob objects at least as long as the reconcile window.

**Python SDK exporter on 5xx** ([03b-sdk-retry.py](03b-sdk-retry.py), langfuse 4.17.0 + opentelemetry-exporter-otlp-proto-http 1.45.0, a local server returning scripted codes, [results/03b-sdk-retry.jsonl](results/03b-sdk-retry.jsonl)). Source: `opentelemetry/exporter/otlp/common/http.py` (`_RETRYABLE_STATUS_CODES` = 429, 502, 503, 504; `_MAX_RETRIES` = 6; backoff `2**n` ± 20 %, `Retry-After` wins; never past the deadline) and `langfuse/_client/client.py:363` (timeout = `LANGFUSE_TIMEOUT`, default 5).

| Server answers | Attempts | Gaps | Delivered |
|---|---|---|---|
| 500, then 200 | 1 | — | no (dropped, `Failed to export spans batch code: 500`) |
| 502 / 503 / 504 twice, then 200 | 3 | ~1.1 s, ~2.2 s | yes |
| 503 always, timeout 5 (default) | 3 | 0.99, 2.11 s | no, after 3.1 s |
| 503 always, `timeout=30` | 6 | 1.2, 2.3, 3.8, 7.1, 15.5 s | no, after 29.9 s |
| 401, then 200 | 1 | — | no |

### 04 — Database-level separation on one ClickHouse

Instances A (web :3100) and B (web :3200), each with a worker, on the stack's ClickHouse 26.8.22.13: `CLICKHOUSE_DB=lf_a` / `lf_b`, ClickHouse users `lf_a` / `lf_b` with `GRANT ALL ON lf_a.*` / `lf_b.*` only (from a `users.d` file: the image's `clickhouse` user has no access management), Postgres databases `lf_a` / `lf_b`, Redis logical DBs 1 / 2 (`REDIS_CONNECTION_STRING`), blob prefixes `a/` / `b/`. Run 2026-11-04 13:12–13:16 UTC, Langfuse 4.56.0, OSS. Log: [results/04-db-separation.txt](results/04-db-separation.txt).

| Check | Result |
|---|---|
| Start A before `lf_a` exists | Postgres migrations run, then `failed to open database: code: 81, message: Database lf_a does not exist` and web stays down. The migration does not create the database: the script builds the URL with `database=${CLICKHOUSE_DB}` (`/app/packages/shared/clickhouse/scripts/up.sh`) and golang-migrate needs it to exist. |
| After `CREATE DATABASE lf_a, lf_b` | both healthy; 17 tables in each; `schema_migrations` latest 51, not dirty (51 shipped); nothing written to `default` |
| Ingest 100 traces into each | 400 / 400 rows in `lf_a.events_full` and `lf_b.events_full`, 0 in `default` |
| Read back | A's key reads A's trace (v2 observations: 4 rows); A's key on B's web: 404 |
| As `lf_a`: `lf_b.events_full`, `default.events_full` | `ACCESS_DENIED` (497) |
| As `lf_a`: `SHOW DATABASES`; `system.tables` outside `lf_a` | `lf_a` only; 0 rows |
| As `lf_a`: `system.parts`, `system.query_log` | `ACCESS_DENIED`: ClickHouse 26.8's default `select_from_system_db_requires_grant=true` |
| What Langfuse ran outside its database | `SELECT version()` and three background jobs that failed with 497 without a grant: `background-migration.loadPartitionsFromClickhouse` and `langfuse.queue.event_propagation` (read `system.parts`), `v4-legacy-api-usage-pipeline` (reads `system.query_log`). 62 such log lines per worker in 4 minutes; ingest and reads unaffected. |
| With `GRANT SELECT ON system.parts, system.mutations` | rows of the user's own database (and `system`) only — safe to grant |
| With `GRANT SELECT ON system.query_log` | **every user's queries** (`clickhouse`, `lf_a`, `lf_b`, …), with their text — do not grant across tenants; switch the job off instead (`QUEUE_CONSUMER_V4_LEGACY_API_USAGE_QUEUE_IS_ENABLED=false`, default true, worker env.js:405) |

So storage can be separated per branch or project at database level on one ClickHouse server: one `CLICKHOUSE_DB` and one user per Langfuse instance, the database created beforehand, `GRANT ALL ON <db>.*` plus `SELECT ON system.parts, system.mutations`. Server-wide objects remain shared: the server itself, its `system` logs (readable by an admin), settings profiles and quotas. The separation is per Langfuse **instance**, not per project inside one instance: one instance writes all its projects to its one database. The Helm chart sets `CLICKHOUSE_DB` from `clickhouse.database`. Cluster mode (`CLICKHOUSE_CLUSTER_ENABLED=true`, `ON CLUSTER` DDL) was not run here; it would also need the `CLUSTER` grant (`on_cluster_queries_require_cluster_grant` is true in this image's config).

### 05 — Audit log on the latest Langfuse v4

**Version.** v4.75.0 is the latest v4 release (GitHub releases of langfuse/langfuse, published 2026-11-04 09:26 UTC; read 2026-11-04). Release notes: v4.59.0 *add audit_logs table, staging outbox and event contract* (#18671) and *relay staged audit events into ClickHouse* (#18713); v4.73.0 *add the read-access audit gate and record two routes* (#19211: tRPC `events.byTraceId` and `GET /api/public/traces/{traceId}`, gate `LANGFUSE_AUDIT_LOG_ACCESS_EVENTS` = `org` (default) / `enforced` / `disabled`, org flag `accessAuditLogEnabled` default false); v4.74.0 *always record support access reads*; v4.75.0 nothing on audit logs.

**Run.** `LANGFUSE_VERSION=4.75.0` appended to `_base/.env` (the only change for the default pass), `EE=1` overlay, own compose project `langfuse-hols-v4audit` on fresh volumes — a 4.75 schema cannot be taken back to 4.56.0, so the stack's own volumes were never migrated. Second pass: `LANGFUSE_AUDIT_LOG_ACCESS_EVENTS=enforced` (overlay `audit`). Then the override line was removed, the project deleted with its volumes, and the v4 stack started again on 4.56.0 OSS (`check.sh v4`: ready). 2026-11-04 13:23–13:28 UTC. Log: [results/05-audit-log.txt](results/05-audit-log.txt), actions: [results/05-actions.tsv](results/05-actions.tsv).

| Action (how) | HTTP | Postgres `audit_logs` | Access event (staging) default / enforced |
|---|---|---|---|
| prompt create, label update, delete (public API, project key) | 201, 200, 204 | `prompt` create, update, delete (API key) | — |
| prompt get | 200 | — | — / — |
| org API key create (admin API) | 201 | `apiKey` create | — |
| project create, rename (public API, org key) | 201, 200 | **none** | — |
| project API key create, list, delete | 201, 200, 200 | `apiKey` create, delete | — |
| SCIM user create; org role → VIEWER; project role; member list; member remove | 201, 200, 200, 200, 200 | `orgMembership` create, update, delete; `projectMembership` create | — |
| project delete | 202 | `project` delete | — |
| UI trace detail (tRPC `events.byTraceId`, session login) | 200 | — | none / **1 × `access` `trace` `read`** |
| `GET /api/public/traces/{id}`, `/api/public/traces`, `/api/public/sessions[/{id}]` | 404 | — | none / none — these v1 endpoints answer *not available on deployments running in Langfuse v4 events_only mode* |
| `GET /api/public/v2/observations?traceId=…` | 200 | — | none / none |
| batch export request (tRPC `batchExport.create`) | 200 | `batchExport` create (user) | — |
| admin ingestion replay of one OTel file | 200 | — | — (answer: `Unsupported replay type: otel`) |

- **ClickHouse `audit_logs` stayed empty in both passes** (0 rows; 29 columns from `id` to `inserted_at`). Access events stay in the Postgres outbox `audit_log_staging` (1 row after the enforced pass). Source: the relay starts only `if (env.NEXT_PUBLIC_LANGFUSE_CLOUD_REGION && LANGFUSE_AUDIT_LOG_RELAY_ENABLED === "true")`, comment *Only in cloud deployments* (`/app/worker/dist/app.js:628-633`, worker 4.75.0). Change events go to the Postgres `audit_logs` table, as before, and to the web log (`Audit log: prompt.create … by API_KEY …`).
- Read coverage on self-hosted v4.75.0 in `events_only`: one route, the UI trace detail, and only with `enforced`. Lists, exports and the v2 public API record no read; `GET /api/public/traces/{id}` is unavailable in `events_only`, so its v4.73.0 recording does not apply. The `org` mode's switch is shown only to internal users (#19211), so on self-hosted `enforced` is the way to get reads.
- Not covered: UI-side CRUD (tRPC) — the public API path was used; org settings changes; the `org` opt-in path.

### Not done, and why

- Test 02 was run while containers of other projects used the same Docker VM; see the per-step `foreign_cpu_pct`. The first attempt (`results/02-sizing-contended.*`) ran under ~6 CPUs of foreign load and was discarded.
- Two web replicas were not run (no load balancer in the compose stack); web scale-out is therefore not measured.
- No real cloud object store: the S3 call counts are MinIO's; provider request-rate limits were not exercised. The `SlowDown` → 503 path is from source only.
- ClickHouse in cluster mode and the Helm chart on a cluster were not run for these tests.

---

## 한국어

자체 호스팅 Langfuse v4 검토(맥락: 규제를 받는 금융권 배포)를 위한 공백 점검 다섯 가지를 **2026-11-04** 공유 v4 스택(`_base/`, Docker Compose 단일 노드)에서 실행했습니다. 01–04는 **Langfuse v4.56.0 / SDK 4.17.0 / CH 26.8.22.13**(`events_only`, 기존 볼륨, 따로 적지 않으면 OSS 모드), 05는 최신 v4 릴리스 **Langfuse v4.75.0**(2026-11-04 09:26 UTC 공개)에 EE 오버레이와 새 볼륨으로 실행했습니다. Docker 29.9.2, Compose v5.6.1, Python 3.12.14, opentelemetry-exporter-otlp-proto-http 1.45.0, Helm 4.3.1(렌더만, chart langfuse 2.2.1). 클라우드 리소스와 모델 호출은 없습니다. 아래의 사실은 모두 이미지 안의 어느 파일에서 읽었는지, 수치는 모두 어느 실행인지 밝힙니다. 원본 결과: [`results/`](results/).

**클러스터가 아니라 노트북입니다.** 노트북 한 대의 Docker Desktop VM(12 CPU, 16 GiB)이고 부하 생성기도 같은 호스트에서 돌았습니다. 02부터는 다른 프로젝트의 컨테이너가 같은 VM에서 돌고 있었습니다(단계마다 기록). 시간 수치는 구성 사이의 비율로 읽고, 용량 약속으로 읽지 마세요.

### 요약

| 질문 | 답 (따로 "소스"라고 적지 않으면 이 스택에서 측정) |
|---|---|
| Blob storage(S3) 호출 수는 무엇이 정하나? | **OTLP POST 하나당 PutObject 1회(web) + GetObject 1회(worker).** 분당 4,020 trace를 POST당 1 trace로 보내면 PUT 67/s, POST당 10 trace면 6.7/s, 67 trace면 1/s. 서버 변수로는 횟수가 바뀌지 않았습니다(네 가지 시도). |
| 그럼 blob 호출을 줄이는 손잡이는? | 클라이언트 쪽 배치뿐입니다. SDK의 `flush_at` / `flush_interval`(`LANGFUSE_FLUSH_AT` 기본 512 span, `LANGFUSE_FLUSH_INTERVAL` 기본 5초) 또는 Langfuse 앞의 OpenTelemetry Collector batch processor. |
| ClickHouse insert는? | worker 하나당 `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS`(기본 1000 ms)마다 `events_full` insert 1회. 기본값에서 1/s, 5000 ms에서 0.2/s. |
| `LANGFUSE_TRACE_BATCH_*`는 무엇인가? | (소스) 수집 배치가 아닙니다. Topics 요약용으로 trace 단위 배치를 잡고, `NEXT_PUBLIC_LANGFUSE_CLOUD_REGION`이 있을 때(Langfuse Cloud)만 동작합니다. 여기서 켜 보았지만 변화 없음. |
| 분당 4,000 요청 기준의 사이징 | 이 노트북에서 2 CPU web 하나 + 2 CPU worker 하나가 **분당 4,000 trace**(관측치 4 × 11 KB, OTLP JSON 약 2.9 MB/s)를 다른 부하가 없던 세 번의 실행에서 지연 p95 1.6–1.9초로 소화했고 8,000에서 실패했습니다. **병목은 web**(약 2 CPU 사용)이었고 worker는 약 0.3–0.6 CPU를 썼으며 worker를 하나 더 붙여도 한계는 오르지 않았습니다. 아래 티어 제안에서 `values-base.yaml`이 large입니다. |
| 구성 요소가 죽어도 관측치가 모두 도착하나? | **아니요. 다만 수락된 것은 영구 손실되지 않았습니다.** 각각 20초 SIGKILL, 12,000건 전송: worker −4, web −1,596(클라이언트 포기), ClickHouse −1,972, Redis −8, MinIO −1,524(클라이언트가 500 수신). 서버 쪽 손실(worker, ClickHouse, Redis)은 모두 blob storage에 남아 있었고 [`03c-reconcile.sh`](03c-reconcile.sh)로 다시 처리해 12,000 / 12,000이 됐습니다. 클라이언트 쪽 손실(web, MinIO 중단)은 Langfuse에 도달하지 않았습니다. |
| Python SDK는 5xx에 어떻게 하나? | 429 / 502 / 503 / 504와 연결 오류를 1, 2, 4, 8, 16초 간격으로 최대 6회 재시도하되 **`LANGFUSE_TIMEOUT`(기본 5초) 안에서만** 하므로 기본값에선 약 3초 동안 3회입니다. **500은 재시도하지 않고** 배치를 버립니다. |
| ClickHouse 서버 하나에 인스턴스마다 DB 하나? | **됩니다.** `CLICKHOUSE_DB`를 migration, 수집, 조회가 모두 따릅니다. 사용자 A는 B의 DB에서 `ACCESS_DENIED`, `SHOW DATABASES`에는 자기 DB만 보입니다. DB는 먼저 만들어 두어야 합니다. 자기 DB 밖으로는 `system.parts`와 `system.query_log`를 읽습니다(백그라운드 작업). 권한이 없으면 그 작업만 실패하고 수집과 조회는 정상입니다. `system.query_log`를 주면 모든 사용자의 쿼리가 보입니다. |
| v4.75.0에서 감사 로그에 남는 것은? | Postgres `audit_logs`: prompt 생성/수정/삭제, API 키 생성/삭제, 조직 멤버십 생성/수정/삭제, 프로젝트 멤버십 생성, 프로젝트 삭제, batch export 생성. **남지 않음**: 프로젝트 생성/수정, 모든 조회. 조회는 `LANGFUSE_AUDIT_LOG_ACCESS_EVENTS=enforced`(또는 조직 opt-in)일 때 UI trace 상세(`events.byTraceId`)만 남고, `GET /api/public/traces/{id}`는 `events_only`에서 404입니다. ClickHouse `audit_logs` 테이블은 자체 호스팅에서 **비어 있습니다**: relay가 Langfuse Cloud에서만 돕니다. |

### 파일

| 파일 | 하는 일 |
|---|---|
| [lib.sh](lib.sh) | 공용 함수: `ops_compose`(기본 스택 + 이 실습의 오버레이), `ops_apply` / `ops_restore`, `ch`, `s3_counts`(MinIO 요청 카운터), `run_load`(부하 → 안정화 대기 → 측정) |
| [loadgen.py](loadgen.py) | 재사용 가능한 open-loop OTLP/HTTP 생성기: `--rpm`(분당 trace), `--obs`, `--prompt-bytes`, `--output-bytes`, `--traces-per-post`, `--read-ratio`, `--retry-deadline`(SDK 재시도 규칙). 합성 payload, run id를 trace tag와 metadata로. 표준 라이브러리만 사용 |
| [01-batching.sh](01-batching.sh) | 01: 분당 4,020 trace에서 시나리오 6개, 각각 S3 PUT/GET과 ClickHouse insert |
| [02-sizing.sh](02-sizing.sh) | 02: worker 1개, 2 CPU worker 1개, 2 CPU worker 2개의 부하 사다리 + 조회 혼합 단계 |
| [03-failures.sh](03-failures.sh) | 03: 태그된 부하 중 worker, web, ClickHouse, Redis, MinIO를 하나씩 kill |
| [03b-sdk-retry.py](03b-sdk-retry.py) | 03: 정해진 5xx를 돌려주는 서버에 대한 SDK exporter 동작(Langfuse 불필요) |
| [03c-reconcile.sh](03c-reconcile.sh), [requeue-otel.js](requeue-otel.js) | 03: 실행별 blob 파일과 `events_full` 행 대조, `--replay`로 모자란 파일을 OTel 큐에 다시 넣기 |
| [04-db-separation.sh](04-db-separation.sh) | 04: ClickHouse 하나에 DB·사용자를 하나씩 가진 인스턴스 A, B |
| [05-audit-log.sh](05-audit-log.sh) | 05: 최신 v4 + EE에서 CRUD와 조회, 이어서 Postgres와 ClickHouse 감사 테이블 확인 |
| [99-restore.sh](99-restore.sh) | 중단된 실행 뒤 일반 OSS 스택으로 복구 |
| `docker-compose.{knobs,cpu2,worker2,cpu2w2,dbsep,audit}.yml` | `_base/docker-compose.yml` 위의 오버레이(같은 프로젝트 `langfuse-hols-v4`) |
| [clickhouse-users-dbsep.xml](clickhouse-users-dbsep.xml) | 04의 ClickHouse 사용자(`users.d/`, 끝나면 삭제) |
| [values-ingest.yaml](values-ingest.yaml) | 01의 손잡이를 chart 2.2.1용 Helm values로, `labs/v4/langfuse-k8s/values-base.yaml` 위에 얹음 |

### 실행

```bash
_base/bin/up.sh v4                                   # OSS 스택. 모든 스크립트가 이 상태로 끝납니다
cd labs/v4/langfuse-ops-checks
./01-batching.sh            # 약 10분
./02-sizing.sh              # 약 30분. LADDER="2000 4000 …" SECS=60 READ_RATIO=0.1
./03-failures.sh            # 약 20분. OUTAGE=20 RETRY_DEADLINE=5, 또는 ./03-failures.sh clickhouse
.venv-v4/bin/python 03b-sdk-retry.py                 # 저장소 루트 기준: ../../../.venv-v4/bin/python
./03c-reconcile.sh --replay
./04-db-separation.sh       # 약 5분. CLEANUP=0이면 A, B를 남겨 둠
./05-audit-log.sh 4.75.0    # 약 6분. 별도 프로젝트와 볼륨, 그동안 스택은 멈춤
./99-restore.sh             # 실행이 중단됐을 때만
```

`PY=<python>`으로 `loadgen.py`의 인터프리터를 고릅니다(표준 라이브러리만 사용, 기본 `.venv-v4/bin/python`, 없으면 `python3`). 스크립트는 하나씩 실행하세요. 스택의 web과 worker를 다시 만듭니다.

### 01 — Worker 배치와 blob storage 호출 빈도

**호출이 생기는 곳(소스, 4.56.0).** web의 OTLP 경로는 요청마다 `OtelIngestionProcessor.publishToOtelIngestionQueue`를 한 번 부릅니다. 요청의 `resourceSpans`를 객체 하나 `events/otel/<project>/<yyyy>/<mm>/<dd>/<hh>/<mi>/<uuid>.json`으로 쓰고(`uploadJson`) `otel-ingestion-job` 하나를 큐에 넣습니다(`@langfuse/shared/dist/src/server/otel/OtelIngestionProcessor.js:177-186`). worker는 job마다 그 객체를 한 번 내려받고(`/app/worker/dist/queues/otelIngestionQueue.js:336`), `events_only`에서는 관측치를 `ClickhouseWriter`로 `events_full`에 씁니다. writer는 테이블마다 `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_BATCH_SIZE`행이 쌓이거나 `…_WRITE_INTERVAL_MS`마다 flush합니다(`/app/worker/dist/services/ClickhouseWriter/index.js:36-37, 87`). 업로드에서 S3 `SlowDown`이 나면 **503과 `Retry-After: 2`**로 바꿔 SDK가 재시도하게 하고(`@langfuse/shared/dist/src/server/services/s3ThrottleError.js`), 다른 업로드 오류는 500입니다.

**변수와 기본값**(worker: `/app/worker/dist/env.js`, web·worker 공용: `@langfuse/shared/dist/src/env.js`, 모두 4.56.0 이미지):

| 변수 | 기본값 | 위치 | 바꾸는 것 |
|---|---|---|---|
| `LANGFUSE_OTEL_INGESTION_QUEUE_PROCESSING_CONCURRENCY` | 5 | worker env.js:101 | worker당 동시 OTel job 수 |
| `LANGFUSE_OTEL_INGESTION_SECONDARY_QUEUE_PROCESSING_CONCURRENCY` | 1 | worker env.js:105 | 위와 같음, 보조 큐(`LANGFUSE_SECONDARY_OTEL_INGESTION_QUEUE_ENABLED_PROJECT_IDS`) |
| `LANGFUSE_INGESTION_QUEUE_PROCESSING_CONCURRENCY` / `…_SECONDARY_…` | 20 / 5 | worker env.js:205, 209 | 레거시 `/api/public/ingestion` job |
| `LANGFUSE_OTEL_INGESTION_QUEUE_SHARD_COUNT`, `LANGFUSE_INGESTION_QUEUE_SHARD_COUNT` | 1, 1 | shared env.js:192-200 | Redis 큐 shard 수 |
| `LANGFUSE_INGESTION_QUEUE_DELAY_MS` | 15000 | shared env.js:188 | 레거시 수집 job 지연(OTel 아님) |
| `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_BATCH_SIZE` | 1000 | worker env.js:214 | ClickHouse insert당 행 수 상한 |
| `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS` | 1000 | worker env.js:218 | writer flush 간격 |
| `LANGFUSE_INGESTION_CLICKHOUSE_MAX_ATTEMPTS` | 3 | worker env.js:222 | writer가 행을 **버리기** 전 재시도 수(03) |
| `CLICKHOUSE_ASYNC_INSERT_MAX_DATA_SIZE`, `…_BUSY_TIMEOUT_MS`, `…_BUSY_TIMEOUT_MIN_MS` | 미설정 | shared env.js:146-148 | 서버 쪽 async insert 버퍼(insert는 async insert로 실행: `query_log`의 `AsyncInsertFlush`) |
| `LANGFUSE_S3_CONCURRENT_WRITES` | 50 | shared env.js:267 | S3 클라이언트당 소켓 수(`StorageService.js:96`) |
| `LANGFUSE_S3_UPLOAD_ENABLE_BUFFERED`, `…_MAX_PART_ATTEMPTS`, `…_MAX_CONCURRENT_PARTS` | false, 3, 3 | shared env.js:268-280 | export의 multipart 업로드(이벤트 아님) |
| `LANGFUSE_S3_RATE_ERROR_SLOWDOWN_ENABLED`, `…_TTL_SECONDS` | false, 3600 | shared env.js:357-360 | SlowDown 시 프로젝트의 레거시 수집을 보조 큐로 |
| `LANGFUSE_S3_EVENT_KEY_MAX_SEGMENT_BYTES` | 2048 | shared env.js:10 | 키 세그먼트 길이 |
| `LANGFUSE_ENABLE_BLOB_STORAGE_FILE_LOG` | true | worker env.js:309 | `blob_storage_file_log` 행. `events_only`의 OTel에서는 한 줄도 쓰이지 않음 |
| `LANGFUSE_TRACE_BATCH_INGESTION_ENABLED`, `…_SAMPLING_RATE`, `…_DISPATCHER_ENABLED`, `QUEUE_CONSUMER_TRACE_BATCH_QUEUE_IS_ENABLED` | false, 0, false, false | worker env.js:112-125 | Topics trace 배치, Cloud 전용(아래) |
| `LANGFUSE_TRACE_BATCH_CONCURRENCY`, `…_MAX_THREADS`, `…_REQUEST_TIMEOUT_MS`, `…_MAX_PENDING_SUMMARY_BYTES` | 2, 2, 40000, 100 MiB | worker env.js:130-149 | 〃 |
| `LANGFUSE_TRACE_BATCH_MAX_SIZE`, `…_MAX_BATCH_EVENT_UPDATES`, `…_MAX_BATCH_SERIALIZED_BYTES`, `…_MAX_TRACE_EVENT_UPDATES`, `…_MAX_TRACE_SERIALIZED_BYTES` | 60, 1500, 64 MiB, 5000, 50 MiB | worker env.js:161-187 | 〃 |
| `LANGFUSE_TRACE_BATCH_STRATEGY`, `…_IDLE_MS`, `…_PENDING_TTL_MS`, `…_DISPATCH_INTERVAL_MS`, `…_MAX_BLOCK_SIZE`, `…_EXPERIMENT_ID`, `…_READ_ENABLED`, `…_TRANSCRIPT_METRICS_ENABLED` | project, 600000(리전 `DEV`는 120000), 7200000, 30000, 미설정, 미설정, false, false | worker env.js:126-200, 801-803 | 〃 |

`LANGFUSE_TRACE_BATCH_*`는 동작하는 모든 곳에서 `NEXT_PUBLIC_LANGFUSE_CLOUD_REGION`을 확인합니다. 추적(`features/traceBatching/traceBatching.js:492-493, 601-602`, `features/otel-ingestion/processOtelEvents.js:94-95`), dispatcher와 큐 consumer(`app.js:129-145`). consumer는 Topics용으로 trace 전체를 요약합니다(`queues/traceBatchQueue.js`). 이 변수가 없는 자체 호스팅에서는 아무 일도 하지 않습니다.

**측정**(2026-11-04 12:18–12:27 UTC, 분당 4,020 trace = 67/s로 60초, trace당 관측치 4개, 관측치마다 입력 10 KB + 출력 1 KB, worker 1개, 시나리오마다 web과 worker를 새로 만든 뒤; MinIO의 `minio_s3_requests_total`과 `system.query_log`에서 집계, [results/01-batching.jsonl](results/01-batching.jsonl)):

| 시나리오 | POST당 trace | POST/s | S3 PUT (/s) | S3 GET | `events_full` insert (/s) | 도착 / 전송 관측치 | 지연 p95 |
|---|---|---|---|---|---|---|---|
| 기본값 | 1 | 67 | 4,020 (67) | 4,020 | 60 (1.0) | 16,080 / 16,080 | 0.09초 |
| `…_WRITE_BATCH_SIZE=10000`, `…_WRITE_INTERVAL_MS=5000` | 1 | 67 | 4,020 (67) | 4,020 | **12 (0.2)** | 16,080 / 16,080 | 0.05초 |
| `LANGFUSE_OTEL_INGESTION_QUEUE_PROCESSING_CONCURRENCY=20`, `LANGFUSE_S3_CONCURRENT_WRITES=10` | 1 | 67 | 4,020 (67) | 4,020 | 60 (1.0) | 16,080 / 16,080 | 0.03초 |
| `LANGFUSE_TRACE_BATCH_*` 켬(수집, sampling 1, max size 600, dispatcher, consumer) | 1 | 67 | 4,020 (67) | 4,020 | 60 (1.0) | 16,080 / 16,080 | 0.31초 |
| 클라이언트: POST당 10 trace | 10 | 6.7 | **402 (6.7)** | 402 | 60 (1.0) | 16,080 / 16,080 | 0.26초 |
| 클라이언트: POST당 67 trace | 67 | 1 | **60 (1.0)** | 60 | 58 (1.0) | 16,080 / 16,080 | 1.53초 |

- **Blob 호출을 줄이는 것:** 더 적고 큰 POST, 즉 클라이언트 설정입니다. Python SDK는 프로세스 하나가 `flush_interval`(5초)마다 또는 `flush_at` span(512개)마다 중 먼저 오는 쪽으로 POST를 하나 보내므로, blob 호출 빈도는 trace/초가 아니라 대략 *프로세스 수 × max(1/5초, 초당 span / 512)*입니다. 작은 프로세스가 많다면 Langfuse 앞의 OpenTelemetry Collector `batch` processor가 같은 일을 합니다.
- **Blob 호출을 줄이지 못하는 것:** 큐 동시성, `LANGFUSE_S3_CONCURRENT_WRITES`(소켓 상한이지 호출 수가 아님), ClickHouse writer 손잡이, `LANGFUSE_TRACE_BATCH_*`.
- **ClickHouse insert를 줄이는 것:** `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS`(상한은 `…_BATCH_SIZE`). 행은 최대 한 간격 늦게 보입니다. 지연 열에는 이것이 드러나지 않습니다. `events_full.created_at`은 worker가 행을 만들 때 찍히고(`IngestionService/index.js:238`) writer 버퍼보다 앞이기 때문입니다.
- `query_log`의 `written_rows`는 가끔 `events_core` materialized view 행까지 셉니다(5000 ms 시나리오에서 두 배). `events_core` 행 수는 모든 실행에서 `events_full`과 정확히 같았습니다.
- 공식 chart 2.2.1용 Helm values: [values-ingest.yaml](values-ingest.yaml). 키는 `langfuse.worker.pod.additionalEnv`(worker), `langfuse.web.pod.additionalEnv`(web), `langfuse.additionalEnv`(둘 다)이고, 2.2.1에는 `langfuse.worker.additionalEnv`가 없습니다. `LANGFUSE_S3_CONCURRENT_WRITES`는 chart 자체 키 `s3.concurrency.writes`가 있어 두 deployment에 변수를 렌더합니다. `values-base.yaml` + `values-kind.yaml` + `values-ingest.yaml`을 `helm template`(`clickhouse.crdCheck=false`)으로 렌더해 deployment마다 변수가 한 번씩 나오는 것을 확인했습니다. 클러스터에 설치하지는 않았습니다.

### 02 — 부하 생성기와 사이징

**생성기.** [loadgen.py](loadgen.py)는 open loop입니다. trace *i*는 서버가 어떻든 *t0 + i · 60 / rpm*에 보내므로 느린 서버는 낮은 전송률이 아니라 지연으로 드러나고, `sender_behind_s`는 생성기 자체가 밀렸는지 알려 줍니다(여기서는 0.01초를 넘은 적이 없음). 매개변수: `--rpm`(분당 trace, 애플리케이션 요청 하나 = trace 하나), `--obs`(trace당 관측치), `--prompt-bytes` / `--output-bytes`(모든 관측치, ClickHouse가 압축해 버리지 않게 임의 단어), `--traces-per-post`(클라이언트 배치), `--read-ratio`(보낸 trace당 조회 수, public v2 API로 trace 상세와 관측치 목록을 번갈아 — `GET /api/public/traces/{id}`는 `events_only`에서 404), `--retry-deadline`(SDK 재시도 규칙, 03). 지연 = `events_full.created_at − start_time`. `created_at`은 ClickHouse writer 버퍼 전에 worker가 찍으므로 UI에 보이는 시점은 최대 쓰기 간격(1초)만큼 늦습니다.

**실행**(2026-11-04 13:28–13:52 UTC, Langfuse 4.56.0, trace당 관측치 4개 각 입력 10 KB + 출력 1 KB, 단계당 60초, 통과 = 지연 p95 ≤ 2초이고 손실 없음; POST당 1 trace는 [results/02-sizing.jsonl](results/02-sizing.jsonl), 10 trace는 [results/02-sizing-tpp10.jsonl](results/02-sizing-tpp10.jsonl)). "다른 CPU"는 단계 시작 시 같은 Docker VM에 있던 다른 프로젝트 컨테이너의 CPU %, "스택 CPU"는 단계 중간에 한 번 잰 값(두 번째 묶음만).

| 구성 | 분당 trace | POST당 trace | 결과 | 지연 p50 / p95 / max | 수락 p95 | 다른 CPU | 스택 CPU |
|---|---|---|---|---|---|---|---|
| worker 1, 제한 없음 | 2,000 | 1 | PASS | 0.02 / 0.30 / 1.07초 | 151 ms | 113 % | — |
| worker 1, 제한 없음 | 4,000 | 1 | PASS | 0.02 / 0.68 / 1.73초 | 627 ms | 79 % | — |
| worker 1, 제한 없음 | 8,000 | 1 | FAIL | 6.98 / 11.87 / 12.49초 | 1,859 ms | 111 % | — |
| web + worker 각 2 CPU | 2,000 | 1 | PASS | 0.02 / 0.97 / 2.24초 | 716 ms | 125 % | — |
| web + worker 각 2 CPU | 4,000 | 1 | PASS | 0.04 / 1.57 / 2.95초 | 1,410 ms | 6 % | — |
| web + worker 각 2 CPU | 8,000 | 1 | FAIL | 19.52 / 22.66 / 23.10초 | 2,621 ms | 6 % | — |
| web + worker 2개 각 2 CPU | 2,000 | 1 | PASS | 0.02 / 0.68 / 1.50초 | 669 ms | 259 % | — |
| web + worker 2개 각 2 CPU | 4,000 | 1 | FAIL | 0.30 / 2.85 / 3.80초 | 1,799 ms | 99 % | — |
| web + worker 각 2 CPU(반복) | 4,000 | 1 | FAIL | 0.25 / 9.82 / 10.73초 | 2,632 ms | 0 % → 단계 중에 부하가 들어옴 | — |
| web + worker 각 2 CPU | 4,000 | 10 | FAIL | 0.70 / 7.03 / 11.97초 | 3,731 ms | 117 % | web 214, worker 39 |
| web + worker 2개 각 2 CPU | 4,000 | 10 | FAIL | 0.42 / 4.90 / 7.26초 | 4,066 ms | 680 % | web 258, worker 60 + 31 |
| web + worker 각 2 CPU | 4,000 | 10 | PASS | 0.20 / 1.80 / 2.58초 | 1,321 ms | 0 % | web 81, worker 28 |
| 〃 + trace당 조회 0.1(조회 366회, 조회 p95 1,372 ms) | 4,000 | 10 | PASS | 0.18 / 1.90 / 2.90초 | 1,443 ms | 1 % | web 28, worker 161 |

이 실행이 뒷받침하는 것과 그렇지 않은 것:

- **분당 4,000 trace가 이 노트북에서 2 CPU web 하나의 한계선입니다.** 다른 부하가 없던 세 번은 모두 통과(p95 1.57, 1.80, 1.90초), 다른 CPU가 99 % 이상이던 실행은 모두 실패했고, 8,000은 다른 부하가 없어도 실패했습니다. 다른 부하가 약 6 CPU이던 첫 시도는 2,000에서 이미 실패해 버렸습니다([results/02-sizing-contended.jsonl](results/02-sizing-contended.jsonl)).
- **한계는 worker가 아니라 web의 OTLP 수신입니다.** 부하가 늘면 수락 지연이 커지고 worker는 한가합니다(분당 4,000에서 0.3–0.6 CPU). worker를 하나 더 붙여도 나아지지 않았습니다. web 확장(로드 밸런서 뒤 복제본 2개)은 여기서 실행하지 않았습니다.
- POST당 10 trace로도 이번 실행에서는 한계가 오르지 않았습니다. 초당 바이트는 같고 web이 모두 파싱합니다.
- trace당 조회 0.1은 수집 지연을 바꾸지 않았고 조회 p95는 1.4초였습니다.
- 노트북 한 대, Docker VM 하나, 다른 프로젝트의 부하: 절대 수치가 아니라 **비율**(약 44 KB trace 분당 4,000개당 web 약 2 CPU, worker 약 0.5 CPU)을 쓰고 여유를 두고 잡으세요.

**분당 4,000 요청 기준의 티어**(요청 하나 = 관측치 약 4개, 약 44 KB의 trace 하나; ClickHouse는 여기서 측정하지 않음 — large는 `values-base.yaml` 그대로이고 나머지는 가설). 모든 티어가 가용성을 위해 web과 worker를 2개씩, 컨테이너당 문서상 최소 2 CPU / 4 GiB를 유지하므로 small과 medium은 주로 HPA 상한과 ClickHouse에서 large와 다릅니다:

| 티어 | 분당 요청 | web | worker | ClickHouse(1 shard × 3 replica) |
|---|---|---|---|---|
| small | ≤ 1,000 | 2 × 2 CPU / 4 GiB, HPA 없음 | 2 × 2 CPU / 4 GiB, HPA 없음 | 2 CPU / 8 GiB, 각 128 GiB(가설) |
| medium | ≤ 2,000 | 2 × 2 CPU / 4 GiB, HPA 최대 3 | 2 × 2 CPU / 4 GiB, HPA 최대 3 | 4 CPU / 16 GiB, 각 256 GiB(가설) |
| large = [`values-base.yaml`](../langfuse-k8s/values-base.yaml) | 4,000 + 여유 | 2 × 2 CPU / 4 GiB, HPA 2–4, 50 % | 2 × 2 CPU / 4 GiB, HPA 2–6, 50 % | 6 CPU / 24 GiB, 각 512 GiB |

HPA 목표 50 %에서 2 CPU web pod 두 개는 확장 전에 약 2 CPU의 일을 하므로 측정된 분당 4,000 정도이고, pod 네 개면 그 두 배쯤입니다. worker 쪽은 측정이 요구하는 것보다 여유가 몇 배 큽니다. 2개로 두는 이유는 처리량이 아니라 03의 메모리 손실 구간 때문입니다.

### 03 — 장애 시 수집 손실

**구성**(2026-11-04 12:34–13:01 UTC, Langfuse 4.56.0, OSS, worker 1개): 구성 요소마다 분당 1,200 trace × 관측치 4개(초당 80개)를 150초, trace마다 run id 태그. t = 30초에 `docker kill`(SIGKILL), 20초 중단 뒤 `docker start`. 생성기는 Python SDK 기본값처럼 재시도합니다(5초 기한). 끝나면 그 실행의 행 수가 60초 동안 변하지 않을 때까지 기다립니다. 기대값 = 서버가 2xx로 답한 관측치. 결과: [results/03-failures.jsonl](results/03-failures.jsonl), 실행별 샘플 `results/03-<component>-samples.tsv`.

| 20초 kill | 전송 | 수락(2xx) | 도착 | 서버 손실 | 클라이언트 손실 | 클라이언트가 본 것 | 그동안 원본 이벤트 위치 | [03c-reconcile.sh](03c-reconcile.sh) 뒤 |
|---|---|---|---|---|---|---|---|---|
| worker | 12,000 | 12,000 | 11,996 | **4** | 0 | 모두 200 (p99 4.5초) | blob storage + Redis: `otel-ingestion-queue` 대기 87 → 382 → 722 job, 재시작 뒤 약 20초에 소진 | 모자란 파일 2개 → 재투입 → **12,000** |
| web | 12,000 | 10,404 | 10,404 | 0 | **1,596** | 연결 오류 1,284회, 재시도 885회 | 없음: POST가 Langfuse에 닿지 않음 | 재처리할 것 없음 |
| ClickHouse | 12,000 | 12,000 | 10,028 | **1,972** | 0 | 모두 200 | blob storage. worker의 ClickHouse writer가 메모리에 들고 있다가 `ClickhouseWriter: Max attempts reached, dropped N events_full record(s)`를 26번 기록 | 모자란 파일 493개 → 재투입 → **12,000** |
| Redis | 12,000 | 12,000 | 11,992 | **8** | 0 | 모두 200, p99 28초(요청이 Redis를 기다림) | web이 요청을 붙잡고 있었고 중단 중 blob 쓰기 없음(PutObject 카운터 정지) | 모자란 파일 3개 → 재투입 → **12,000** |
| MinIO | 12,000 | 10,476 | 10,476 | 0 | **1,524** | **500** 381회(재시도 안 됨) | 없음: 업로드 실패로 POST가 거절됨 | 재처리할 것 없음 |

- **서버 쪽 손실은 실제로 있고 클라이언트는 모릅니다.** 원인은 둘입니다. worker가 죽을 때 ClickHouse writer 버퍼에 있던 행(worker, Redis), 그리고 ClickHouse가 멈춘 동안 insert가 `LANGFUSE_INGESTION_CLICKHOUSE_MAX_ATTEMPTS`(3)번 실패해 writer가 버린 행. 두 경우 모두 OTel job은 이미 완료되어 BullMQ가 재시도하지 않습니다(`otel-ingestion-queue` job: 6회, 지수 5초 backoff, `@langfuse/shared/dist/src/server/redis/otelIngestionQueue.js:48-52`; 어느 실행에서도 실패 job은 없었음). writer 코드의 주석: `TODO - Add to a dead letter queue in Redis rather than dropping`(`ClickhouseWriter/index.js:329`). 경보를 걸 신호: 위 로그 줄과 metric `langfuse.queue.clickhouse_writer.rows_dropped`.
- **원본 이벤트는 남습니다.** 수락된 POST는 모두 blob storage에 있었고, `events_full`의 모든 행은 원본 파일을 `blob_storage_file_path`에 갖고 있습니다. [03c-reconcile.sh](03c-reconcile.sh)가 실행별로 둘을 대조하고 모자란 파일을 [requeue-otel.js](requeue-otel.js)로 다시 넣었습니다. 세 실행 모두 서로 다른 관측치 12,000개로 돌아왔습니다(재처리된 행은 `span_id` 기준 중복 제거. 병합 전까지 `count()`에 중복 4행).
- **공식 replay 엔드포인트는 여기서 OTel 파일에 쓸 수 없습니다.** `LANGFUSE_S3_EVENT_UPLOAD_PREFIX=events/`에서 `POST /api/admin/ingestion-replay`는 전체 키 `events/otel/…`를 `Unsupported replay type: otel`로 거절하고, `events/` 없는 키는 큐에 넣지만 worker가 내려받지 못합니다(`NoSuchKey`) ([results/03c-admin-replay.txt](results/03c-admin-replay.txt)). 4.75.0에서도 같은 `Unsupported replay type: otel`(05). 그래서 직접 재투입했습니다.
- **클라이언트 쪽 손실**은 web이나 blob storage가 멈췄을 때 생깁니다. web은 연결을 거부하고, 업로드 실패는 500으로 답하는데 SDK는 500을 재시도하지 않습니다. SDK의 기본 5초 기한은 약 3초의 중단만 덮습니다.
- **100% 수집을 KPI로 삼으려면:** blob storage와 `events_full`을 주기적으로 대조하고(이 스크립트의 방식) `rows_dropped`에 경보를 겁니다. 클라이언트의 `LANGFUSE_TIMEOUT`을 늘립니다(30초면 약 30초 동안 6회, 아래). web과 blob storage는 고가용성으로 운영합니다. 이 둘의 중단은 Langfuse가 데이터를 받기 전에 잃습니다. blob 객체는 적어도 대조 주기보다 오래 보관합니다.

**5xx에 대한 Python SDK exporter**([03b-sdk-retry.py](03b-sdk-retry.py), langfuse 4.17.0 + opentelemetry-exporter-otlp-proto-http 1.45.0, 정해진 코드를 돌려주는 로컬 서버, [results/03b-sdk-retry.jsonl](results/03b-sdk-retry.jsonl)). 소스: `opentelemetry/exporter/otlp/common/http.py`(`_RETRYABLE_STATUS_CODES` = 429, 502, 503, 504; `_MAX_RETRIES` = 6; backoff `2**n` ± 20 %, `Retry-After` 우선; 기한을 넘지 않음)와 `langfuse/_client/client.py:363`(timeout = `LANGFUSE_TIMEOUT`, 기본 5).

| 서버 응답 | 시도 | 간격 | 전달 |
|---|---|---|---|
| 500, 이어서 200 | 1 | — | 안 됨(버림, `Failed to export spans batch code: 500`) |
| 502 / 503 / 504 두 번, 이어서 200 | 3 | 약 1.1초, 약 2.2초 | 됨 |
| 항상 503, timeout 5(기본) | 3 | 0.99, 2.11초 | 안 됨, 3.1초 뒤 |
| 항상 503, `timeout=30` | 6 | 1.2, 2.3, 3.8, 7.1, 15.5초 | 안 됨, 29.9초 뒤 |
| 401, 이어서 200 | 1 | — | 안 됨 |

### 04 — ClickHouse 하나에서 DB 단위 분리

스택의 ClickHouse 26.8.22.13 위에 인스턴스 A(web :3100)와 B(web :3200), 각각 worker 하나: `CLICKHOUSE_DB=lf_a` / `lf_b`, `GRANT ALL ON lf_a.*` / `lf_b.*`만 가진 ClickHouse 사용자 `lf_a` / `lf_b`(`users.d` 파일로 정의: 이미지의 `clickhouse` 사용자에는 access management가 없음), Postgres DB `lf_a` / `lf_b`, Redis 논리 DB 1 / 2(`REDIS_CONNECTION_STRING`), blob prefix `a/` / `b/`. 2026-11-04 13:12–13:16 UTC, Langfuse 4.56.0, OSS. 로그: [results/04-db-separation.txt](results/04-db-separation.txt).

| 확인 | 결과 |
|---|---|
| `lf_a`가 없을 때 A 시작 | Postgres migration 뒤 `failed to open database: code: 81, message: Database lf_a does not exist`, web은 뜨지 않음. migration은 DB를 만들지 않습니다. 스크립트가 URL을 `database=${CLICKHOUSE_DB}`로 만들고(`/app/packages/shared/clickhouse/scripts/up.sh`) golang-migrate는 DB가 있어야 합니다. |
| `CREATE DATABASE lf_a, lf_b` 뒤 | 둘 다 정상, 각각 테이블 17개, `schema_migrations` 최신 51, dirty 아님(이미지에 51개), `default`에는 아무것도 쓰지 않음 |
| 각각 100 trace 수집 | `lf_a.events_full`과 `lf_b.events_full`에 400 / 400행, `default`에 0 |
| 다시 읽기 | A의 키로 A의 trace 조회(v2 observations 4행), A의 키로 B의 web: 404 |
| `lf_a`로 `lf_b.events_full`, `default.events_full` | `ACCESS_DENIED`(497) |
| `lf_a`로 `SHOW DATABASES`, `lf_a` 밖의 `system.tables` | `lf_a`만, 0행 |
| `lf_a`로 `system.parts`, `system.query_log` | `ACCESS_DENIED`: ClickHouse 26.8 기본 `select_from_system_db_requires_grant=true` |
| Langfuse가 자기 DB 밖에서 실행한 것 | `SELECT version()`, 그리고 권한이 없어 497로 실패한 백그라운드 작업 셋: `background-migration.loadPartitionsFromClickhouse`와 `langfuse.queue.event_propagation`(`system.parts` 읽기), `v4-legacy-api-usage-pipeline`(`system.query_log` 읽기). 4분 동안 worker마다 이런 로그 62줄, 수집과 조회는 영향 없음 |
| `GRANT SELECT ON system.parts, system.mutations`를 주면 | 사용자 자신의 DB(와 `system`) 행만 보임 — 주어도 안전 |
| `GRANT SELECT ON system.query_log`를 주면 | **모든 사용자의 쿼리**(`clickhouse`, `lf_a`, `lf_b`, …)와 그 텍스트가 보임 — 테넌트 사이에는 주지 말고 작업을 끄세요(`QUEUE_CONSUMER_V4_LEGACY_API_USAGE_QUEUE_IS_ENABLED=false`, 기본 true, worker env.js:405) |

따라서 ClickHouse 서버 하나에서 지점이나 프로젝트별로 저장소를 DB 단위로 나눌 수 있습니다. Langfuse 인스턴스마다 `CLICKHOUSE_DB` 하나와 사용자 하나, DB는 미리 생성, `GRANT ALL ON <db>.*`와 `SELECT ON system.parts, system.mutations`. 서버 전체 객체는 여전히 공유됩니다: 서버 자체, `system` 로그(관리자는 읽을 수 있음), settings profile과 quota. 분리 단위는 Langfuse **인스턴스**이지 한 인스턴스 안의 프로젝트가 아닙니다. 인스턴스 하나는 모든 프로젝트를 자기 DB 하나에 씁니다. Helm chart는 `clickhouse.database`로 `CLICKHOUSE_DB`를 설정합니다. 클러스터 모드(`CLICKHOUSE_CLUSTER_ENABLED=true`, `ON CLUSTER` DDL)는 여기서 실행하지 않았습니다. 그때는 `CLUSTER` 권한도 필요합니다(이 이미지 설정의 `on_cluster_queries_require_cluster_grant`가 true).

### 05 — 최신 Langfuse v4의 감사 로그

**버전.** v4.75.0이 최신 v4 릴리스입니다(langfuse/langfuse GitHub releases, 2026-11-04 09:26 UTC 공개, 2026-11-04 확인). 릴리스 노트: v4.59.0 *add audit_logs table, staging outbox and event contract*(#18671), *relay staged audit events into ClickHouse*(#18713). v4.73.0 *add the read-access audit gate and record two routes*(#19211: tRPC `events.byTraceId`와 `GET /api/public/traces/{traceId}`, 스위치 `LANGFUSE_AUDIT_LOG_ACCESS_EVENTS` = `org`(기본) / `enforced` / `disabled`, 조직 플래그 `accessAuditLogEnabled` 기본 false). v4.74.0 *always record support access reads*. v4.75.0에는 감사 로그 관련 항목이 없습니다.

**실행.** `_base/.env`에 `LANGFUSE_VERSION=4.75.0`을 덧붙이고(기본 패스의 유일한 변경), `EE=1` 오버레이, 새 볼륨의 별도 compose 프로젝트 `langfuse-hols-v4audit`. 4.75 스키마는 4.56.0으로 되돌릴 수 없으므로 스택 자체의 볼륨은 migration하지 않았습니다. 두 번째 패스: `LANGFUSE_AUDIT_LOG_ACCESS_EVENTS=enforced`(오버레이 `audit`). 끝나면 덧붙인 줄을 지우고, 그 프로젝트를 볼륨째 삭제하고, v4 스택을 4.56.0 OSS로 다시 띄웠습니다(`check.sh v4`: ready). 2026-11-04 13:23–13:28 UTC. 로그: [results/05-audit-log.txt](results/05-audit-log.txt), 동작: [results/05-actions.tsv](results/05-actions.tsv).

| 동작(방법) | HTTP | Postgres `audit_logs` | 조회 이벤트(staging) 기본 / enforced |
|---|---|---|---|
| prompt 생성, label 수정, 삭제(public API, 프로젝트 키) | 201, 200, 204 | `prompt` create, update, delete(API key) | — |
| prompt 조회 | 200 | — | — / — |
| 조직 API 키 생성(admin API) | 201 | `apiKey` create | — |
| 프로젝트 생성, 이름 변경(public API, 조직 키) | 201, 200 | **없음** | — |
| 프로젝트 API 키 생성, 목록, 삭제 | 201, 200, 200 | `apiKey` create, delete | — |
| SCIM 사용자 생성, 조직 역할 → VIEWER, 프로젝트 역할, 멤버 목록, 멤버 제거 | 201, 200, 200, 200, 200 | `orgMembership` create, update, delete, `projectMembership` create | — |
| 프로젝트 삭제 | 202 | `project` delete | — |
| UI trace 상세(tRPC `events.byTraceId`, 세션 로그인) | 200 | — | 없음 / **`access` `trace` `read` 1건** |
| `GET /api/public/traces/{id}`, `/api/public/traces`, `/api/public/sessions[/{id}]` | 404 | — | 없음 / 없음 — 이 v1 엔드포인트는 *not available on deployments running in Langfuse v4 events_only mode*로 답함 |
| `GET /api/public/v2/observations?traceId=…` | 200 | — | 없음 / 없음 |
| batch export 요청(tRPC `batchExport.create`) | 200 | `batchExport` create(user) | — |
| OTel 파일 하나의 admin ingestion replay | 200 | — | —(답: `Unsupported replay type: otel`) |

- **ClickHouse `audit_logs`는 두 패스 모두 비어 있었습니다**(0행, `id`부터 `inserted_at`까지 29열). 조회 이벤트는 Postgres outbox `audit_log_staging`에 머뭅니다(enforced 패스 뒤 1행). 소스: relay는 `if (env.NEXT_PUBLIC_LANGFUSE_CLOUD_REGION && LANGFUSE_AUDIT_LOG_RELAY_ENABLED === "true")`일 때만 시작하고 주석은 *Only in cloud deployments*입니다(`/app/worker/dist/app.js:628-633`, worker 4.75.0). 변경 이벤트는 예전처럼 Postgres `audit_logs` 테이블과 web 로그(`Audit log: prompt.create … by API_KEY …`)로 갑니다.
- `events_only`의 자체 호스팅 v4.75.0에서 조회 기록 범위: UI trace 상세 한 경로, 그것도 `enforced`일 때만. 목록, export, v2 public API는 조회를 남기지 않고, `GET /api/public/traces/{id}`는 `events_only`에서 쓸 수 없으므로 v4.73.0의 기록 대상이 적용되지 않습니다. `org` 모드의 스위치는 내부 사용자에게만 보이므로(#19211) 자체 호스팅에서 조회를 남기려면 `enforced`입니다.
- 다루지 않은 것: UI 쪽 CRUD(tRPC) — public API 경로를 썼음, 조직 설정 변경, `org` opt-in 경로.

### 하지 못한 것과 이유

- 02는 다른 프로젝트의 컨테이너가 같은 Docker VM을 쓰는 중에 실행했습니다. 단계별 `foreign_cpu_pct`를 보세요. 첫 시도(`results/02-sizing-contended.*`)는 다른 부하가 약 6 CPU를 쓰는 중이어서 버렸습니다.
- web 복제본 2개는 실행하지 않았습니다(compose 스택에 로드 밸런서가 없음). 따라서 web 확장은 측정하지 않았습니다.
- 실제 클라우드 object store가 아닙니다. S3 호출 수는 MinIO 기준이고 클라우드 사업자의 요청 빈도 제한은 시험하지 않았습니다. `SlowDown` → 503 경로는 소스로만 확인했습니다.
- 이 점검에서는 ClickHouse 클러스터 모드와 클러스터 위의 Helm chart를 실행하지 않았습니다.
