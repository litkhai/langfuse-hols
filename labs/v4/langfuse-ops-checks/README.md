# Langfuse v4 operations checks: blob-storage call rate, sizing, collection loss, per-database separation, audit log, loss mitigations, ClickHouse per tier and as a cluster

[English](#english) | [한국어](#한국어)

---

## English

Eight gap tests for a self-hosted Langfuse v4 review (context: a regulated financial deployment), run on the shared v4 stack (`_base/`, Docker Compose, single node) on **2026-11-04**. Tests 01–04 and 06–07 ran on **Langfuse v4.56.0 / SDK 4.17.0 / CH 26.8.22.13** (`events_only`, existing volumes, OSS mode except where noted); test 05 ran on **Langfuse v4.75.0** (latest v4 release, published 2026-11-04 09:26 UTC) with the EE overlay on fresh volumes; test 08 on the 01–04 pins in its own compose project on fresh volumes (ClickHouse 1 shard × 3 replicas + Keeper 26.8.22.13). Tests 06–08 add HAProxy 3.2.24 and OpenTelemetry Collector contrib 0.162.0. Docker 29.9.2, Compose v5.6.1, Python 3.12.14, opentelemetry-exporter-otlp-proto-http 1.45.0, Helm 4.3.1 (render only, chart langfuse 2.2.1). No cloud resources, no model calls. Every fact below names the file it was read from in the images; every number names its run. Raw results: [`results/`](results/).

**Laptop, not a cluster.** One Docker Desktop VM (12 CPUs, 16 GiB) on one laptop, load generator on the same host. From test 02 on, containers of other projects were running on the same VM (recorded per step; during the first half of 06 a kind cluster of another project too); timings are ratios between set-ups, not capacity promises.

### The short answer

| Question | Answer (measured on this stack unless marked "source") |
|---|---|
| What sets the blob-storage (S3) call rate? | **One PutObject (web) + one GetObject (worker) per OTLP POST.** 4,020 traces/min sent one trace per POST: 67 PUT/s; ten traces per POST: 6.7 PUT/s; 67 per POST: 1 PUT/s. No server variable changed the count (four variants tried). |
| Which knob reduces blob calls then? | Client-side batching only: the SDK's `flush_at` / `flush_interval` (`LANGFUSE_FLUSH_AT`, default 512 spans; `LANGFUSE_FLUSH_INTERVAL`, default 5 s) or an OpenTelemetry Collector batch processor in front of Langfuse. |
| And ClickHouse inserts? | One insert into `events_full` per `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS` (default 1000 ms) per worker: 1/s at the defaults, 0.2/s at 5000 ms. |
| What is `LANGFUSE_TRACE_BATCH_*`? | (source) Not an ingestion batcher. It schedules whole-trace batches for Topics summaries and runs only when `NEXT_PUBLIC_LANGFUSE_CLOUD_REGION` is set (Langfuse Cloud). Turned on here: no change. |
| Sizing vs a 4,000 requests/min baseline | (ClickHouse: 07.) On this laptop one web + one worker at 2 CPUs each sustained **4,000 traces/min** (4 × 11 KB observations, ~2.9 MB/s of OTLP JSON) with lag p95 1.6–1.9 s in the three runs without foreign load, and failed at 8,000. **Web was the bottleneck** (~2 CPUs busy), the worker used ~0.3–0.6 CPU; a second worker did not raise the limit. Proposed tiers below, with `values-base.yaml` as the large one. |
| Does every observation arrive when a component dies? | **No — but nothing accepted is lost for good.** 20 s SIGKILL each, 12,000 observations sent: worker −4, web −1,596 (client gave up), ClickHouse −1,972, Redis −8, MinIO −1,524 (client got 500). Every server-side loss (worker, ClickHouse, Redis) was still in blob storage and was re-processed to 12,000 / 12,000 with [`03c-reconcile.sh`](03c-reconcile.sh). Client-side losses (web down, MinIO down) never reached Langfuse. |
| What does the Python SDK do on 5xx? | Retries 429 / 502 / 503 / 504 and connection errors with backoff 1, 2, 4, 8, 16 s, at most 6 attempts, **within `LANGFUSE_TIMEOUT` (default 5 s)** — so 3 attempts in ~3 s by default. A **500 is not retried**: the batch is dropped. |
| One ClickHouse server, one database per instance? | **Works.** `CLICKHOUSE_DB` is honoured by migrations, ingest and reads; user A gets `ACCESS_DENIED` on B's database and sees only its own in `SHOW DATABASES`. The database must exist first. Outside its database Langfuse reads `system.parts` and `system.query_log` (background jobs); without grants those jobs fail, ingest and reads do not. Granting `system.query_log` shows every user's queries. |
| What lands in the audit log on v4.75.0? | Postgres `audit_logs`: prompt create / update / delete, API key create / delete, org membership create / update / delete, project membership create, project delete, batch export create. **Not**: project create / update, any read. Reads are recorded only with `LANGFUSE_AUDIT_LOG_ACCESS_EVENTS=enforced` (or an org opt-in) and only for the UI trace detail (`events.byTraceId`); `GET /api/public/traces/{id}` answers 404 in `events_only`. The ClickHouse `audit_logs` table stays **empty** on self-hosted: its relay runs only on Langfuse Cloud. |
| Two web replicas behind a load balancer? | **Removes the web-outage loss if the load balancer retries.** HAProxy over two webs, one SIGKILLed for 20 s: **0** of 12,000 lost (03, one web: 1,596), with `retry-on conn-failure empty-response …` + `option redispatch`, buffered requests and a 3 s health-check timeout. The same pair without retries: 80 lost. |
| `LANGFUSE_TIMEOUT=30` on the SDK? | **Helps, does not close it.** The real SDK in one process at 80 spans/s, web down 20 s: 420 and 792 lost (default 5 s: 2,004 and 2,992). A batch's attempts fall at 0, 1, 3, 7, 15 s (a sixth only if it fits in 30 s), and while one batch retries the SDK's 2,048-span queue fills and drops; raise `OTEL_BSP_MAX_QUEUE_SIZE` too. |
| An OpenTelemetry Collector with a disk queue in front? | **For web outages and Collector restarts, yes; for blob-storage outages, no.** Web down 20 s: 0 lost. Collector SIGKILLed with a non-empty `file_storage` queue: 0 of what it had acknowledged lost (clients lost 1,456 while it was down). MinIO down: web answers 500, which the `otlphttp` exporter treats as permanent and drops — 1,788 lost; no setting changes that. |
| ClickHouse resources per tier? | (07, one node, 10 traces/POST, 0.1 reads/trace) 1,000 / 2,000 / 4,000 traces/min: **0.52 / 0.65 / 0.89 CPU** (0.21 of it idle), peak anon memory 1.9 / 1.7 / 2.2 GiB, ~1 INSERT and 1.9 new parts per second at every rate, **~2.0 KB disk per observation = 10.6 / 21.7 / 43.1 GiB per day per replica**. The proposed 2 CPU / 8 GiB and 4 CPU / 16 GiB hold with headroom; their 128 / 256 GiB disks hold ~8 days. |
| ClickHouse 1 shard × 3 replicas? | **Works** with `CLICKHOUSE_CLUSTER_ENABLED=true` and `CLICKHOUSE_CLUSTER_NAME`: Replicated tables on all three. Langfuse talks to **one** host (`CLICKHOUSE_URL`): killing another replica lost 0 (caught up within 4 s); killing that host lost 1,604 of 12,000 (reconciled to 12,000), as on one node. HAProxy over the three as `CLICKHOUSE_URL`: 0 lost. |

### Files

| File | Does |
|---|---|
| [lib.sh](lib.sh) | Shared helpers: `ops_compose` (base stack + this lab's overlays), `ops_apply` / `ops_restore`, `ch`, `s3_counts` (MinIO request counters), `run_load` (load → settle → measure), `timeline_load` (load with scheduled kills and starts → expected vs arrived), `settle_quiet` |
| [loadgen.py](loadgen.py) | Reusable open-loop OTLP/HTTP generator: `--rpm` (traces/min), `--obs`, `--prompt-bytes`, `--output-bytes`, `--traces-per-post`, `--read-ratio`, `--retry-deadline` (SDK retry rule), `--endpoint` (e.g. a Collector). Synthetic payloads, run id as trace tag and metadata. Stdlib only |
| [01-batching.sh](01-batching.sh) | Test 01: six scenarios at 4,020 traces/min, S3 PUT/GET and ClickHouse inserts each |
| [02-sizing.sh](02-sizing.sh) | Test 02: rate ladder for one worker, one worker at 2 CPUs, two workers at 2 CPUs, plus a read-mix step |
| [03-failures.sh](03-failures.sh) | Test 03: kill worker, web, ClickHouse, Redis, MinIO one at a time under tagged load |
| [03b-sdk-retry.py](03b-sdk-retry.py) | Test 03: the SDK exporter against a scripted 5xx server (no Langfuse needed) |
| [03c-reconcile.sh](03c-reconcile.sh), [requeue-otel.js](requeue-otel.js) | Test 03: blob files vs `events_full` rows per run; `--replay` puts short files back on the OTel queue |
| [04-db-separation.sh](04-db-separation.sh) | Test 04: instances A and B on one ClickHouse, one database and one user each |
| [05-audit-log.sh](05-audit-log.sh) | Test 05: CRUD and reads on the latest v4 with EE, then Postgres and ClickHouse audit tables |
| [06-mitigations.sh](06-mitigations.sh) | Test 06: two webs behind HAProxy (with and without retries), a 30 s client deadline, the SDK itself, an OTel Collector with a file-backed queue — each under 03's outage |
| [06b-sdk-outage.py](06b-sdk-outage.py) | Test 06: the Langfuse Python SDK as the client, one process, counting the spans it drops and why |
| [07-clickhouse-tiers.sh](07-clickhouse-tiers.sh) | Test 07: ClickHouse CPU-seconds, memory, inserts, parts, merges, disk growth at 1,000 / 2,000 / 4,000 traces/min |
| [08-clickhouse-cluster.sh](08-clickhouse-cluster.sh) | Test 08: Langfuse in cluster mode on 1 shard × 3 replicas + Keeper; schema check, replica kills, HAProxy over the replicas |
| [99-restore.sh](99-restore.sh) | Back to the normal OSS stack after an interrupted run |
| `docker-compose.{knobs,cpu2,worker2,cpu2w2,dbsep,audit,web2,otelcol}.yml` | Overlays on `_base/docker-compose.yml` (same project `langfuse-hols-v4`) |
| [haproxy-web2.cfg](haproxy-web2.cfg), [haproxy-web2-noretry.cfg](haproxy-web2-noretry.cfg), [otelcol.yaml](otelcol.yaml) | Test 06's load balancer and Collector configs |
| [docker-compose.ch3.yml](docker-compose.ch3.yml), [ch3-cluster.xml](ch3-cluster.xml), [ch3-keeper.xml](ch3-keeper.xml), [haproxy-ch3.cfg](haproxy-ch3.cfg) | Test 08's cluster, used as its own project `langfuse-hols-v4ch3` |
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
./06-mitigations.sh         # ~50 min; or e.g. ./06-mitigations.sh lb otel-minio
RUNS_FILE=results/06-mitigations.jsonl ./03c-reconcile.sh <run_id ...>
./07-clickhouse-tiers.sh    # ~20 min; RATES="1000 2000 4000" SECS=240 IDLE=60
KEEP=1 ./08-clickhouse-cluster.sh   # ~15 min; own project, v4 stack stopped meanwhile
OPS_PROJECT=langfuse-hols-v4ch3 RUNS_FILE=results/08-cluster.jsonl ./03c-reconcile.sh --replay <run_id>
./08-clickhouse-cluster.sh down     # remove the cluster and its volumes, start the v4 stack again
./99-restore.sh             # only after an interrupted run
```

`PY=<python>` picks the interpreter for `loadgen.py` (stdlib only; default `.venv-v4/bin/python`, else `python3`); 06's SDK scenarios need the venv with langfuse 4.17.0. Run one script at a time: they recreate the stack's web and worker.

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
- **The limit is the web's OTLP intake, not the worker.** Accept latency grows with load while the worker idles (0.3–0.6 CPU at 4,000/min); a second worker did not help. Web scale-out was run for availability, not throughput (06).
- Ten traces per POST did not raise the limit on this run: the bytes per second are the same, and the web parses them all.
- Reads at 0.1 per trace did not change ingest lag; read p95 was 1.4 s.
- One laptop, one Docker VM, foreign load from other projects: use the **ratio** (≈ 2 web CPUs per 4,000 traces/min of ~44 KB traces; ≈ 0.5 worker CPU for the same) and size with headroom, not the absolute numbers.

**Tiers relative to 4,000 requests/min** (one request = one trace of ~4 observations and ~44 KB). web and worker from this test; **ClickHouse measured in [07](#07--clickhouse-resources-per-tier)** (2026-11-04, one ClickHouse 26.8.22.13 node, 10 traces per POST, 0.1 API reads per trace; a laptop, not a cluster: read the ClickHouse figures as ingest plus a light read mix — UI dashboards over long ranges were not measured and are what the CPU headroom is for). Every tier keeps two replicas of web and worker for availability and the documented minimum of 2 CPU / 4 GiB per container, so small and medium differ from large mainly in their HPA ceilings and ClickHouse. Disk per replica = GiB per day × retention days ÷ 0.7 (30 % kept free for merges); 30 days shown:

| Tier | Requests/min | web | worker | ClickHouse per replica (1 shard × 3 replicas) | ClickHouse measured (07) |
|---|---|---|---|---|---|
| small | ≤ 1,000 | 2 × 2 CPU / 4 GiB, no HPA | 2 × 2 CPU / 4 GiB, no HPA | 2 CPU / 8 GiB; disk 10.6 GiB/day → **~450 GiB for 30 days** (128 GiB ≈ 8 days) | 0.52 CPU, 1.9 GiB anon peak, 10.6 GiB/day |
| medium | ≤ 2,000 | 2 × 2 CPU / 4 GiB, HPA max 3 | 2 × 2 CPU / 4 GiB, HPA max 3 | 4 CPU / 16 GiB; disk 21.7 GiB/day → **~930 GiB for 30 days** (256 GiB ≈ 8 days) | 0.65 CPU, 1.7 GiB, 21.7 GiB/day |
| large = [`values-base.yaml`](../langfuse-k8s/values-base.yaml) | 4,000 with headroom | 2 × 2 CPU / 4 GiB, HPA 2–4 at 50 % | 2 × 2 CPU / 4 GiB, HPA 2–6 at 50 % | 6 CPU / 24 GiB; disk 43.1 GiB/day → **~1.8 TiB for 30 days** (`values-base.yaml`'s 512 GiB ≈ 8 days) | 0.89 CPU, 2.2 GiB, 43.1 GiB/day |

CPU and memory of all three ClickHouse sizes hold with about 4× (small) to 7× (large) headroom over the measured ingest; the disks are what the measurements change. Disk scales with payload: these traces carry 11 KB per observation, so smaller prompts need proportionally less (~2.0 KB on disk per 11 KB observation here). Blob storage keeps the raw OTLP JSON in addition and was not sized here.

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
- **For 100 % collection as a KPI:** reconcile blob storage against `events_full` on a schedule (this script's logic) and alert on `rows_dropped`; raise `LANGFUSE_TIMEOUT` on the clients (30 s gave 6 attempts over ~30 s, below; 06 shows what it buys under load); run web and blob storage highly available, because their outages lose data before Langfuse has it (06: two webs behind a retrying load balancer lost nothing; nothing in front of Langfuse saves a blob-storage outage); keep blob objects at least as long as the reconcile window.

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

So storage can be separated per branch or project at database level on one ClickHouse server: one `CLICKHOUSE_DB` and one user per Langfuse instance, the database created beforehand, `GRANT ALL ON <db>.*` plus `SELECT ON system.parts, system.mutations`. Server-wide objects remain shared: the server itself, its `system` logs (readable by an admin), settings profiles and quotas. The separation is per Langfuse **instance**, not per project inside one instance: one instance writes all its projects to its one database. The Helm chart sets `CLICKHOUSE_DB` from `clickhouse.database`. Cluster mode (`CLICKHOUSE_CLUSTER_ENABLED=true`, `ON CLUSTER` DDL) was not run with per-database users (08 ran it with the admin user); it would also need the `CLUSTER` grant (`on_cluster_queries_require_cluster_grant` is true in this image's config).

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

### 06 — Loss mitigations: two webs behind a load balancer, a 30 s SDK timeout, an OpenTelemetry Collector

**Set-up** (2026-11-04 14:52–16:06 UTC, Langfuse 4.56.0 / SDK 4.17.0 / ClickHouse 26.8.22.13, OSS, one worker, existing volumes): 03's load and outage — 1,200 traces/min × 4 observations of 10 KB in + 1 KB out (80 observations/s), one trace per POST unless noted, 150 s; the component is SIGKILLed at t = 35 s and started at t = 55 s. Sent = observations the client produced; arrived = distinct `span_id` of the run in `events_full` once unchanged for 60 s. HAProxy 3.2.24, OpenTelemetry Collector contrib 0.162.0. A kind cluster of another project (~4 CPUs) shared the Docker VM until ~15:05 UTC; 06 counts losses, not timing. [06-mitigations.sh](06-mitigations.sh), [06b-sdk-outage.py](06b-sdk-outage.py), [results/06-mitigations.jsonl](results/06-mitigations.jsonl), samples `results/06-<scenario>-samples.tsv`, blob check [results/06-reconcile.txt](results/06-reconcile.txt).

| Scenario | Killed 20 s | Client (retry budget) | Sent | Client got 2xx | Arrived | Lost | Why |
|---|---|---|---|---|---|---|---|
| 03, for reference | web | loadgen (5 s) | 12,000 | 10,404 | 10,404 | 1,596 | connections refused for longer than the 5 s budget |
| **a** two webs + HAProxy, retries on ([haproxy-web2.cfg](haproxy-web2.cfg)) | web-1 | loadgen (5 s) | 12,000 | 12,000 | 12,000 | **0** | the 21 requests in flight on web-1 at the kill still got 200 (no 502 reached the client) and the rest went to web-2; the client saw only 200 (p99 3.1 s), no client retry |
| **a** same, no retries ([haproxy-web2-noretry.cfg](haproxy-web2-noretry.cfg)) | web-1 | loadgen (5 s) | 12,000 | 11,920 | 11,920 | **80** | 3 × 502 (in flight on web-1) and 106 × 503: web-1 came back into the pool on its DNS answer before its check passed (connection refused), and web-2 failed one 3 s check under the burst ("no server available") ([log](results/06-lb-noretry-haproxy-log.txt)) |
| **b** one web, retry deadline 30 s, 64 sender threads | web | loadgen (30 s) | 12,000 | 11,864 | 11,864 | **136** | the exporter rule tries at 0, 1, 3, 7, 15 s and a sixth time at ~28–34 s only if it fits the budget: POSTs that started early in the outage ran out before web answered. With 64 threads busy in backoff, most POSTs waited in the generator's queue and made their first attempt after web was back, which flatters this run |
| **b** same, 1,024 threads | web | loadgen (30 s) | 12,000 | 8,944 | 10,212 | **1,788** | each POST retries on its own clock; at the restart hundreds of retries reached the one web at once and many took > 30 s, so the client gave up on 3,056 observations of which 1,268 had been stored |
| **b** the SDK itself, `LANGFUSE_TIMEOUT=30`, one process (two runs) | web | SDK (30 s) | 12,000 | — | 11,580 / 11,208 | **420 / 792** | run 2 (counted): 1 of 28 export batches (420 spans) ran out of its 30 s; 0 spans dropped from the queue. Run 1: 792, consistent with one batch plus queue overflow (see below) |
| **b** the SDK itself, default 5 s (two runs) | web | SDK (5 s) | 12,000 | — | 9,996 / 9,008 | **2,004 / 2,992** | run 2: 4 of 28 batches failed (2,004 spans) |
| **c** Collector, run 1 | web | loadgen → Collector (5 s) | 12,000 | 12,000 | 12,000 | **0** | the Collector answered 200 from its queue, logged 30 × `Exporting failed. Will retry the request after interval.` and delivered after web returned (2 requests twice; one row per span remains) |
| **c** Collector, run 2 | MinIO | loadgen → Collector (5 s) | 12,000 | 12,000 | 10,212 | **1,788** | web answered **500** (blob upload failed); the Collector dropped those requests (31 × `Exporting failed. Dropping data.`, `otelcol_exporter_send_failed_spans` = 1,788). Never in blob storage: nothing to reconcile. (Same arrived count as the 1,024-thread run by coincidence; separate runs.) |
| **c** Collector, run 3 | web 30–60 s and the Collector 36–56 s | loadgen → Collector (5 s) | 12,000 | 10,544 | 10,544 | **0** behind the Collector, **1,456** at the client | the file_storage queue (≥ 40 requests at the kill) survived the SIGKILL and drained after both were back (queue 565 → 0 by t ≈ 89 s); the client lost what it sent while the Collector was down (1,192 connection errors) |

A first attempt at **a** (14:38 UTC, no `timeout check`, so 1 s; no warm-up; no HAProxy log) got 503 for 8,239 of 8,303 answers before and after the kill and was discarded and re-run: [results/06-lb-first-attempt.txt](results/06-lb-first-attempt.txt).

**a — the load-balancer settings that mattered** (HAProxy 3.2; the same ideas apply to any L7 proxy):

- `retry-on conn-failure empty-response response-timeout 502 503 504` with `retries 3` and `option redispatch 1`: a request that cannot reach a web, or whose web dies mid-request, goes to the other replica. This made the difference between 0 and 80 lost.
- `option http-buffer-request` with `tune.bufsize` above the largest POST (1 MiB here): HAProxy keeps the whole body, so it can re-send it. A request larger than the buffer is not retried (HAProxy documentation): SDK batches (up to 512 spans × 11 KB ≈ 5.6 MB) need a larger buffer or smaller batches — not run with SDK batches.
- Health check `GET /api/public/health` every 1 s, `fall 2 rise 2`, **`timeout check 3s`**: a busy web answered the check in more than 1 s.
- `resolvers` on Docker's DNS: a killed container's name stops resolving and the server leaves the pool at once; on restart it re-enters on the DNS answer *before* the check passes, which only retries cover.
- Not run: nginx or a Kubernetes ingress. nginx does not pass a POST to the next upstream once it was sent unless `proxy_next_upstream … non_idempotent` is set (nginx documentation); a Kubernetes Service (kube-proxy) does not retry at all.

**b — what `LANGFUSE_TIMEOUT=30` does and does not do.** The SDK's `LangfuseSpanProcessor` is OpenTelemetry's `BatchSpanProcessor` (`langfuse/_client/span_processor.py:98, 197-199`): one exporter thread, a queue of `OTEL_BSP_MAX_QUEUE_SIZE` spans (default 2,048, `opentelemetry/sdk/trace/export/__init__.py:44`) that drops spans when full (`opentelemetry/sdk/_shared_internal/__init__.py:199-203`), and batches of `flush_at` spans every `flush_interval` (5 s: ~400 spans per batch at 80 spans/s, 28 batches in 150 s). The timeout is the retry budget of *one* batch; while that batch retries, the thread is blocked and the queue fills. So:

- A batch survives an outage only if web answers within its budget: the attempts fall at 0, 1, 3, 7, 15 s (and ~28–34 s if it fits), so 30 s covers ~15 s for sure and up to ~30 s by luck. Here the client-visible outage was ~20 s plus the web's start-up.
- While a batch retries for ~30 s, a process making more than 2,048 / 30 ≈ 68 spans/s overflows the queue; at 80 spans/s run 1 most likely did (792 lost vs one batch of ~430). Raise `OTEL_BSP_MAX_QUEUE_SIZE` to at least *spans per second × budget* per process (memory ≈ queue × span size, 11 KB here).
- The SDK's own warnings (`Queue full, dropping Span.`, `Failed to export spans batch due to timeout…`) are de-duplicated by OpenTelemetry's `DuplicateFilter` (`_shared_internal/__init__.py:33, 76`), so logs undercount; 06b-sdk-outage.py counts by wrapping `BatchProcessor.emit` and `OTLPSpanExporter.export`.
- Many processes, each retrying on its own (the 1,024-thread run), can make it worse: their retries arrive together when web comes back.

**c — Collector config** ([docker-compose.otelcol.yml](docker-compose.otelcol.yml), exact config [otelcol.yaml](otelcol.yaml)): `otlp` receiver (HTTP :4318) → `otlphttp` exporter to `http://langfuse-web:3000/api/public/otel` with `basicauth` (project keys), `timeout: 30s`, `retry_on_failure` (1 s doubling to 30 s, `max_elapsed_time: 300s`), `sending_queue` with `storage: file_storage/queue` on a named volume, `num_consumers: 10`, `queue_size: 100000`; no batch processor (one request in, one request out, so blob counts stay comparable). Lab-only: the container runs as user 0 to write to a fresh volume.

- **Does the Collector retry a 500? No.** `otlphttp` retries only 429, 502, 503, 504 and network errors; every other status is returned as `consumererror.NewPermanent` and dropped (`exporter/otlphttpexporter/otlp.go:233-235, 264-277` in opentelemetry-collector v0.162.0). `retry_on_failure` and `sending_queue` act only on retryable errors, and no exporter setting makes a status retryable. Langfuse answers 500 for a failed blob upload and 503 only for an S3 `SlowDown` (01), so a blob-storage outage is lost at the Collector exactly as at the SDK (03: 1,524 lost). That gap is closed only by highly available blob storage.
- The queue survived a SIGKILL of the Collector (run 3); `file_storage` does not fsync by default, so a host crash (not a process kill) can lose the tail.
- The Collector becomes the hop that clients must reach: its own outage is client-side loss (run 3: 1,456). Run it as a per-node agent or with several replicas behind a load balancer.

**What to recommend from 06:** two or more web replicas behind a load balancer **that retries POSTs on another replica** (0 lost); a Collector with a file-backed queue in front of Langfuse for web outages and Langfuse restarts (0 lost), kept highly available itself; `LANGFUSE_TIMEOUT=30` only together with a larger `OTEL_BSP_MAX_QUEUE_SIZE` — on its own it cut the loss from 2,004–2,992 to 420–792 here, not to zero; and highly available blob storage, because none of the three helps when it is down.

### 07 — ClickHouse resources per tier

**Set-up** (2026-11-04 15:28–15:43 UTC, Langfuse 4.56.0 OSS, ClickHouse 26.8.22.13 on the stack's existing volumes with ~820 MiB of earlier test data, web + worker at 2 CPUs each (overlay `cpu2`, as 02), one worker, no CPU or memory cap on ClickHouse, Docker VM 12 CPUs / 16 GiB, no kind cluster running). Before the steps 60 s without load (idle); then per step 240 s of RATE traces/min × 4 observations (10 KB in + 1 KB out), **10 traces per OTLP POST** (as 02 passed), **0.1 reads per trace** (trace detail and observations list, alternating), 128 sender threads. Measured on the ClickHouse container only: cgroup v2 `cpu.stat` `usage_usec` from the start of the load until 20 s after the rows settled (272 s), per minute of load; `memory.current`, `anon` (`memory.stat`) and ClickHouse `MemoryTracking` sampled every 2 s; `system.query_log` and `system.part_log` for inserts, new parts and merges; growth of active parts' `bytes_on_disk` in database `default`. The sampler's own queries are in the idle figure. [07-clickhouse-tiers.sh](07-clickhouse-tiers.sh), [results/07-clickhouse-tiers.jsonl](results/07-clickhouse-tiers.jsonl), samples `results/07-<rate>-samples.tsv`.

| ClickHouse, one node | idle | 1,000 traces/min | 2,000 traces/min | 4,000 traces/min |
|---|---|---|---|---|
| CPU-seconds per minute (= cores) | 12.7 (0.21) | 31.4 (0.52) | 38.8 (0.65) | 53.1 (0.89) |
| … minus idle | — | 17.0 (0.28) | 24.4 (0.41) | 38.7 (0.65) |
| peak `memory.current` / `anon` / `MemoryTracking` | 2,031 / 820 / 502 MiB | 3,246 / 1,904 / 1,685 MiB | 3,071 / 1,790 / 1,351 MiB | 3,833 / 2,296 / 1,489 MiB |
| INSERT queries / new parts per second | 0 / 0 | 1.0 / 1.9 | 0.9 / 1.9 | 1.0 / 1.9 |
| merges in the step · most running · most active parts of `events_full` | 0 · 1 · 12 | 94 · 2 · 18 | 92 · 2 · 16 | 94 · 2 · 19 |
| disk growth per hour → per day | — | 0.44 → **10.6 GiB** | 0.90 → **21.7 GiB** | 1.80 → **43.1 GiB** |
| disk per observation | — | 1,981 B | 2,019 B | 2,008 B |
| reads: count, p50 / p95 | — | 391, 40 / 311 ms | 783, 42 / 807 ms | 1,564, 35 / 771 ms |
| ingest lag p95, loss | — | 1.09 s, 0 | 1.65 s, 0 | 1.21 s, 0 |
| other containers' CPU at the start | 33 % | 37 % | 15 % | 17 % |

- **Inserts and parts do not grow with the rate.** The worker's writer flushes once per `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS` (1 s) whatever the volume (01), so ClickHouse sees ~1 INSERT/s and ~1.9 new parts/s (`events_full` and its `events_core` materialized view) at every rate, ~93 merges per step and at most 19 active parts — far from any parts limit. What grows is bytes: ~0.12–0.13 CPU per additional 1,000 traces/min.
- **Memory is mostly fixed.** Peak `anon` 1.7–2.2 GiB at every rate, 0.8 GiB idle; the rest of `memory.current` is page cache. ClickHouse sizes its caches from the RAM it sees (16 GiB here), so an 8 GiB replica uses less for caches; this read mix adds little.
- **Disk is ~2.0 KB per observation** (11 KB of input + output each, compressed, `events_full` + `events_core`): per day ≈ traces/min × 4 × 1,440 × 2.0 KB, **per replica** — every replica keeps a full copy. Blob storage keeps the raw OTLP JSON separately (not measured here).
- **Do the proposed sizes hold?** CPU and memory, yes: small (2 CPU / 8 GiB) at ≤ 1,000/min used ~0.5 CPU and ~1.9 GiB; medium (4 CPU / 16 GiB) at ≤ 2,000/min ~0.65 CPU and ~1.7 GiB — ingest alone would fit small; the rest is headroom for UI and analytics queries, which were not measured; large (6 CPU / 24 GiB) at 4,000/min ~0.9 CPU and ~2.2 GiB. **The disks do not**: 128 / 256 / 512 GiB fill in ~12 days at 1,000 / 2,000 / 4,000 traces/min, or ~8 days keeping 30 % free for merges. Size disks from the retention you need.
- In 1 shard × 3 replicas every replica writes or fetches every part and merges it itself, so per-replica CPU, memory and disk ≈ these single-node figures; reads spread only if clients reach all replicas (08).
- Laptop caveats: one node, no replication traffic, load generator on the same host, earlier data on the volume. CPU-seconds count only ClickHouse's own work, so they are not inflated much by foreign load, but they depend on the CPU's speed.

### 08 — ClickHouse 1 shard × 3 replicas

**Set-up** (2026-11-04 15:44–15:57 UTC): own compose project `langfuse-hols-v4ch3` (base file + [docker-compose.ch3.yml](docker-compose.ch3.yml)) on fresh volumes; the v4 stack was stopped meanwhile (same host ports) and started again afterwards, its volumes untouched. Three `clickhouse-server:26.8.22.13` replicas `clickhouse`, `clickhouse-2`, `clickhouse-3` in cluster `langfuse` (1 shard, `internal_replication`, macros from the environment: [ch3-cluster.xml](ch3-cluster.xml)) and one `clickhouse-keeper:26.8.22.13` ([ch3-keeper.xml](ch3-keeper.xml); production runs three). Langfuse 4.56.0 OSS with `CLICKHOUSE_CLUSTER_ENABLED=true`, `CLICKHOUSE_CLUSTER_NAME=langfuse`, `CLICKHOUSE_MIGRATION_URL=clickhouse://clickhouse:9000`. Load as 03 (1,200 traces/min × 4 observations, 10 KB / 1 KB, one trace per POST, 150 s, SDK retry 5 s); SIGKILL at 35 s, start at 55 s. [08-clickhouse-cluster.sh](08-clickhouse-cluster.sh), [results/08-cluster.txt](results/08-cluster.txt), [results/08-cluster.jsonl](results/08-cluster.jsonl), [results/08-reconcile.txt](results/08-reconcile.txt), samples `results/08-<step>-samples.tsv`.

**Migrations.** Healthy 45 s after the first `compose up`, no blocker. With a cluster name other than `default` the migration script renders the canonical migrations for that name (`prepare-migrations.mjs render`, `/app/packages/shared/clickhouse/scripts/up.sh:56-114`); the shipped `migrations/clustered/` files hard-code `ON CLUSTER default`. On each of the three replicas: 12 `ReplicatedReplacingMergeTree`, 1 `ReplicatedMergeTree` (`schema_migrations`), 1 materialized view, 3 views; `schema_migrations` latest 51, not dirty; `events_full` is `ReplicatedReplacingMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}', event_ts, is_deleted)`; `system.replicas`: 3 total, 3 active.

**Which replica Langfuse talks to: one.** `CLICKHOUSE_URL` is a single URL (`CLICKHOUSE_URL: zod.url()`, `@langfuse/shared/dist/src/env.js:132`), and so is `CLICKHOUSE_MIGRATION_URL`. In the first two runs every INSERT went to `clickhouse` (initial INSERT queries per replica 150 / 0 / 0 and 123 / 0 / 0); the others fetched the parts.

| Killed for 20 s | `CLICKHOUSE_URL` | Sent = accepted | Arrived | Lost | INSERTs on replica 1 / 2 / 3 | Killed replica caught up | After [03c-reconcile.sh](03c-reconcile.sh) |
|---|---|---|---|---|---|---|---|
| `clickhouse-2` (not in the URL) | `http://clickhouse:8123` | 12,000 | 12,000 | **0** | 150 / 0 / 0 | within 4 s of its start (first sample) | — |
| `clickhouse` (the URL) | `http://clickhouse:8123` | 12,000 | 10,396 | **1,604** (20 × `Max attempts reached`) | 123 / 0 / 0 | — (no replica got rows meanwhile) | 401 files short → requeued → **12,000** on all three |
| `clickhouse` | `http://chlb:8123`, HAProxy over the three ([haproxy-ch3.cfg](haproxy-ch3.cfg)) | 12,000 | 12,000 | **0** | 45 / 49 / 52 | within 5 s | — |

- **Replicas protect the data, not the ingest path**, unless Langfuse reaches them through something that fails over. With one host in `CLICKHOUSE_URL`, that host's outage is single-node 03 again (1,972 lost there, 1,604 here): the writer drops after 3 attempts, the raw events stay in blob storage, reconcile restores them.
- **A load balancer as `CLICKHOUSE_URL` closed it**: HAProxy with `GET /ping` checks every 1 s (`fall 2`), `retry-on conn-failure empty-response 502 503 504`, `option redispatch`, buffered requests; inserts spread over the three replicas. In Kubernetes the equivalent is a Service over all replicas with a readiness probe — not run here, and kube-proxy does not retry, so the writer's 3 attempts must outlast failure detection.
- Not tested: an INSERT is acknowledged after one replica wrote it (no `insert_quorum`), so rows on a replica whose disk is lost before the others fetched exist only in blob storage; read-after-write through a load balancer may reach a replica a few seconds behind (catch-up here ≤ 5 s); Keeper outage (one Keeper here; ClickHouse documents that Replicated tables go read-only without Keeper); a three-node Keeper; `ON CLUSTER` with a non-admin user (04: needs the `CLUSTER` grant); the Helm chart's cluster mode.

### Not done, and why

- Test 02 was run while containers of other projects used the same Docker VM; see the per-step `foreign_cpu_pct`. The first attempt (`results/02-sizing-contended.*`) ran under ~6 CPUs of foreign load and was discarded.
- Web scale-out was run for availability (06a), not for throughput: two webs behind HAProxy were not put through 02's rate ladder.
- 06 did not run nginx, a Kubernetes ingress or Service, a Collector with a batch processor or several Collector replicas, or `OTEL_BSP_MAX_QUEUE_SIZE` above its default.
- No real cloud object store: the S3 call counts are MinIO's; provider request-rate limits were not exercised. The `SlowDown` → 503 path is from source only.
- ClickHouse in cluster mode ran in Compose (08), not through the Helm chart; Keeper had one node and was not killed; UI read load on ClickHouse (07) was not measured.

---

## 한국어

자체 호스팅 Langfuse v4 검토(맥락: 규제를 받는 금융권 배포)를 위한 공백 점검 여덟 가지를 **2026-11-04** 공유 v4 스택(`_base/`, Docker Compose 단일 노드)에서 실행했습니다. 01–04와 06–07은 **Langfuse v4.56.0 / SDK 4.17.0 / CH 26.8.22.13**(`events_only`, 기존 볼륨, 따로 적지 않으면 OSS 모드), 05는 최신 v4 릴리스 **Langfuse v4.75.0**(2026-11-04 09:26 UTC 공개)에 EE 오버레이와 새 볼륨으로, 08은 01–04와 같은 버전으로 새 볼륨의 별도 compose 프로젝트에서(ClickHouse 1 shard × 3 replica + Keeper 26.8.22.13) 실행했습니다. 06–08에는 HAProxy 3.2.24와 OpenTelemetry Collector contrib 0.162.0이 더해집니다. Docker 29.9.2, Compose v5.6.1, Python 3.12.14, opentelemetry-exporter-otlp-proto-http 1.45.0, Helm 4.3.1(렌더만, chart langfuse 2.2.1). 클라우드 리소스와 모델 호출은 없습니다. 아래의 사실은 모두 이미지 안의 어느 파일에서 읽었는지, 수치는 모두 어느 실행인지 밝힙니다. 원본 결과: [`results/`](results/).

**클러스터가 아니라 노트북입니다.** 노트북 한 대의 Docker Desktop VM(12 CPU, 16 GiB)이고 부하 생성기도 같은 호스트에서 돌았습니다. 02부터는 다른 프로젝트의 컨테이너가 같은 VM에서 돌고 있었습니다(단계마다 기록, 06의 앞쪽 절반에는 다른 프로젝트의 kind 클러스터도). 시간 수치는 구성 사이의 비율로 읽고, 용량 약속으로 읽지 마세요.

### 요약

| 질문 | 답 (따로 "소스"라고 적지 않으면 이 스택에서 측정) |
|---|---|
| Blob storage(S3) 호출 수는 무엇이 정하나? | **OTLP POST 하나당 PutObject 1회(web) + GetObject 1회(worker).** 분당 4,020 trace를 POST당 1 trace로 보내면 PUT 67/s, POST당 10 trace면 6.7/s, 67 trace면 1/s. 서버 변수로는 횟수가 바뀌지 않았습니다(네 가지 시도). |
| 그럼 blob 호출을 줄이는 손잡이는? | 클라이언트 쪽 배치뿐입니다. SDK의 `flush_at` / `flush_interval`(`LANGFUSE_FLUSH_AT` 기본 512 span, `LANGFUSE_FLUSH_INTERVAL` 기본 5초) 또는 Langfuse 앞의 OpenTelemetry Collector batch processor. |
| ClickHouse insert는? | worker 하나당 `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS`(기본 1000 ms)마다 `events_full` insert 1회. 기본값에서 1/s, 5000 ms에서 0.2/s. |
| `LANGFUSE_TRACE_BATCH_*`는 무엇인가? | (소스) 수집 배치가 아닙니다. Topics 요약용으로 trace 단위 배치를 잡고, `NEXT_PUBLIC_LANGFUSE_CLOUD_REGION`이 있을 때(Langfuse Cloud)만 동작합니다. 여기서 켜 보았지만 변화 없음. |
| 분당 4,000 요청 기준의 사이징 | (ClickHouse: 07.) 이 노트북에서 2 CPU web 하나 + 2 CPU worker 하나가 **분당 4,000 trace**(관측치 4 × 11 KB, OTLP JSON 약 2.9 MB/s)를 다른 부하가 없던 세 번의 실행에서 지연 p95 1.6–1.9초로 소화했고 8,000에서 실패했습니다. **병목은 web**(약 2 CPU 사용)이었고 worker는 약 0.3–0.6 CPU를 썼으며 worker를 하나 더 붙여도 한계는 오르지 않았습니다. 아래 티어 제안에서 `values-base.yaml`이 large입니다. |
| 구성 요소가 죽어도 관측치가 모두 도착하나? | **아니요. 다만 수락된 것은 영구 손실되지 않았습니다.** 각각 20초 SIGKILL, 12,000건 전송: worker −4, web −1,596(클라이언트 포기), ClickHouse −1,972, Redis −8, MinIO −1,524(클라이언트가 500 수신). 서버 쪽 손실(worker, ClickHouse, Redis)은 모두 blob storage에 남아 있었고 [`03c-reconcile.sh`](03c-reconcile.sh)로 다시 처리해 12,000 / 12,000이 됐습니다. 클라이언트 쪽 손실(web, MinIO 중단)은 Langfuse에 도달하지 않았습니다. |
| Python SDK는 5xx에 어떻게 하나? | 429 / 502 / 503 / 504와 연결 오류를 1, 2, 4, 8, 16초 간격으로 최대 6회 재시도하되 **`LANGFUSE_TIMEOUT`(기본 5초) 안에서만** 하므로 기본값에선 약 3초 동안 3회입니다. **500은 재시도하지 않고** 배치를 버립니다. |
| ClickHouse 서버 하나에 인스턴스마다 DB 하나? | **됩니다.** `CLICKHOUSE_DB`를 migration, 수집, 조회가 모두 따릅니다. 사용자 A는 B의 DB에서 `ACCESS_DENIED`, `SHOW DATABASES`에는 자기 DB만 보입니다. DB는 먼저 만들어 두어야 합니다. 자기 DB 밖으로는 `system.parts`와 `system.query_log`를 읽습니다(백그라운드 작업). 권한이 없으면 그 작업만 실패하고 수집과 조회는 정상입니다. `system.query_log`를 주면 모든 사용자의 쿼리가 보입니다. |
| v4.75.0에서 감사 로그에 남는 것은? | Postgres `audit_logs`: prompt 생성/수정/삭제, API 키 생성/삭제, 조직 멤버십 생성/수정/삭제, 프로젝트 멤버십 생성, 프로젝트 삭제, batch export 생성. **남지 않음**: 프로젝트 생성/수정, 모든 조회. 조회는 `LANGFUSE_AUDIT_LOG_ACCESS_EVENTS=enforced`(또는 조직 opt-in)일 때 UI trace 상세(`events.byTraceId`)만 남고, `GET /api/public/traces/{id}`는 `events_only`에서 404입니다. ClickHouse `audit_logs` 테이블은 자체 호스팅에서 **비어 있습니다**: relay가 Langfuse Cloud에서만 돕니다. |
| 로드 밸런서 뒤의 web 복제본 2개? | **로드 밸런서가 재시도하면 web 중단 손실이 없어집니다.** web 2개 앞의 HAProxy, 하나를 20초 SIGKILL: 12,000건 중 **0** 손실(03, web 1개: 1,596). `retry-on conn-failure empty-response …` + `option redispatch`, 요청 버퍼링, health check timeout 3초. 같은 구성에서 재시도 없이: 80 손실. |
| SDK의 `LANGFUSE_TIMEOUT=30`? | **도움은 되지만 막지는 못합니다.** 프로세스 하나에서 초당 80 span을 보내는 실제 SDK, web 20초 중단: 420과 792 손실(기본 5초: 2,004와 2,992). 배치의 시도는 0, 1, 3, 7, 15초(6번째는 30초 안에 들어갈 때만)이고, 배치 하나가 재시도하는 동안 SDK의 2,048 span 큐가 차서 버립니다. `OTEL_BSP_MAX_QUEUE_SIZE`도 올려야 합니다. |
| 앞단에 디스크 큐를 둔 OpenTelemetry Collector? | **web 중단과 Collector 재시작에는 됩니다. blob storage 중단에는 안 됩니다.** web 20초 중단: 0 손실. 큐(`file_storage`)가 찬 상태로 Collector를 SIGKILL: 확인해 준 것 중 0 손실(Collector가 멈춘 동안 클라이언트가 1,456 잃음). MinIO 중단: web이 500으로 답하고 `otlphttp` exporter는 이를 영구 오류로 보고 버림 — 1,788 손실, 바꿀 설정 없음. |
| 티어별 ClickHouse 자원? | (07, 노드 1개, POST당 trace 10개, trace당 조회 0.1) 분당 1,000 / 2,000 / 4,000 trace: **0.52 / 0.65 / 0.89 CPU**(그중 0.21은 idle), 최대 anon 메모리 1.9 / 1.7 / 2.2 GiB, 모든 부하에서 초당 약 1 INSERT와 1.9개의 새 part, **관측치당 디스크 약 2.0 KB = 복제본당 하루 10.6 / 21.7 / 43.1 GiB**. 제안한 2 CPU / 8 GiB와 4 CPU / 16 GiB는 여유 있게 맞고, 128 / 256 GiB 디스크는 약 8일 분입니다. |
| ClickHouse 1 shard × 3 replica? | `CLICKHOUSE_CLUSTER_ENABLED=true`와 `CLICKHOUSE_CLUSTER_NAME`으로 **됩니다**: 셋 모두 Replicated 테이블. Langfuse는 호스트 **하나**(`CLICKHOUSE_URL`)에 연결합니다. 다른 복제본을 kill하면 0 손실(4초 안에 따라잡음), 그 호스트를 kill하면 12,000건 중 1,604 손실(대조로 12,000) — 단일 노드와 같습니다. 셋 앞의 HAProxy를 `CLICKHOUSE_URL`로: 0 손실. |

### 파일

| 파일 | 하는 일 |
|---|---|
| [lib.sh](lib.sh) | 공용 함수: `ops_compose`(기본 스택 + 이 실습의 오버레이), `ops_apply` / `ops_restore`, `ch`, `s3_counts`(MinIO 요청 카운터), `run_load`(부하 → 안정화 대기 → 측정), `timeline_load`(정해진 시각의 kill·start가 있는 부하 → 기대값 대 도착), `settle_quiet` |
| [loadgen.py](loadgen.py) | 재사용 가능한 open-loop OTLP/HTTP 생성기: `--rpm`(분당 trace), `--obs`, `--prompt-bytes`, `--output-bytes`, `--traces-per-post`, `--read-ratio`, `--retry-deadline`(SDK 재시도 규칙), `--endpoint`(예: Collector). 합성 payload, run id를 trace tag와 metadata로. 표준 라이브러리만 사용 |
| [01-batching.sh](01-batching.sh) | 01: 분당 4,020 trace에서 시나리오 6개, 각각 S3 PUT/GET과 ClickHouse insert |
| [02-sizing.sh](02-sizing.sh) | 02: worker 1개, 2 CPU worker 1개, 2 CPU worker 2개의 부하 사다리 + 조회 혼합 단계 |
| [03-failures.sh](03-failures.sh) | 03: 태그된 부하 중 worker, web, ClickHouse, Redis, MinIO를 하나씩 kill |
| [03b-sdk-retry.py](03b-sdk-retry.py) | 03: 정해진 5xx를 돌려주는 서버에 대한 SDK exporter 동작(Langfuse 불필요) |
| [03c-reconcile.sh](03c-reconcile.sh), [requeue-otel.js](requeue-otel.js) | 03: 실행별 blob 파일과 `events_full` 행 대조, `--replay`로 모자란 파일을 OTel 큐에 다시 넣기 |
| [04-db-separation.sh](04-db-separation.sh) | 04: ClickHouse 하나에 DB·사용자를 하나씩 가진 인스턴스 A, B |
| [05-audit-log.sh](05-audit-log.sh) | 05: 최신 v4 + EE에서 CRUD와 조회, 이어서 Postgres와 ClickHouse 감사 테이블 확인 |
| [06-mitigations.sh](06-mitigations.sh) | 06: HAProxy 뒤의 web 2개(재시도 있음·없음), 클라이언트 기한 30초, SDK 자체, 파일 큐 OTel Collector — 각각 03의 중단 아래 |
| [06b-sdk-outage.py](06b-sdk-outage.py) | 06: Langfuse Python SDK를 클라이언트로, 프로세스 하나, 버린 span과 이유를 셈 |
| [07-clickhouse-tiers.sh](07-clickhouse-tiers.sh) | 07: 분당 1,000 / 2,000 / 4,000 trace에서 ClickHouse CPU-초, 메모리, insert, part, merge, 디스크 증가 |
| [08-clickhouse-cluster.sh](08-clickhouse-cluster.sh) | 08: 1 shard × 3 replica + Keeper 위의 클러스터 모드 Langfuse. 스키마 확인, 복제본 kill, 복제본 앞 HAProxy |
| [99-restore.sh](99-restore.sh) | 중단된 실행 뒤 일반 OSS 스택으로 복구 |
| `docker-compose.{knobs,cpu2,worker2,cpu2w2,dbsep,audit,web2,otelcol}.yml` | `_base/docker-compose.yml` 위의 오버레이(같은 프로젝트 `langfuse-hols-v4`) |
| [haproxy-web2.cfg](haproxy-web2.cfg), [haproxy-web2-noretry.cfg](haproxy-web2-noretry.cfg), [otelcol.yaml](otelcol.yaml) | 06의 로드 밸런서와 Collector 설정 |
| [docker-compose.ch3.yml](docker-compose.ch3.yml), [ch3-cluster.xml](ch3-cluster.xml), [ch3-keeper.xml](ch3-keeper.xml), [haproxy-ch3.cfg](haproxy-ch3.cfg) | 08의 클러스터, 별도 프로젝트 `langfuse-hols-v4ch3`로 사용 |
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
./06-mitigations.sh         # 약 50분. 또는 예: ./06-mitigations.sh lb otel-minio
RUNS_FILE=results/06-mitigations.jsonl ./03c-reconcile.sh <run_id ...>
./07-clickhouse-tiers.sh    # 약 20분. RATES="1000 2000 4000" SECS=240 IDLE=60
KEEP=1 ./08-clickhouse-cluster.sh   # 약 15분. 별도 프로젝트, 그동안 v4 스택은 멈춤
OPS_PROJECT=langfuse-hols-v4ch3 RUNS_FILE=results/08-cluster.jsonl ./03c-reconcile.sh --replay <run_id>
./08-clickhouse-cluster.sh down     # 클러스터와 볼륨을 지우고 v4 스택을 다시 띄움
./99-restore.sh             # 실행이 중단됐을 때만
```

`PY=<python>`으로 `loadgen.py`의 인터프리터를 고릅니다(표준 라이브러리만 사용, 기본 `.venv-v4/bin/python`, 없으면 `python3`). 06의 SDK 시나리오에는 langfuse 4.17.0이 든 venv가 필요합니다. 스크립트는 하나씩 실행하세요. 스택의 web과 worker를 다시 만듭니다.

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
- **한계는 worker가 아니라 web의 OTLP 수신입니다.** 부하가 늘면 수락 지연이 커지고 worker는 한가합니다(분당 4,000에서 0.3–0.6 CPU). worker를 하나 더 붙여도 나아지지 않았습니다. web 확장은 처리량이 아니라 가용성 목적으로 실행했습니다(06).
- POST당 10 trace로도 이번 실행에서는 한계가 오르지 않았습니다. 초당 바이트는 같고 web이 모두 파싱합니다.
- trace당 조회 0.1은 수집 지연을 바꾸지 않았고 조회 p95는 1.4초였습니다.
- 노트북 한 대, Docker VM 하나, 다른 프로젝트의 부하: 절대 수치가 아니라 **비율**(약 44 KB trace 분당 4,000개당 web 약 2 CPU, worker 약 0.5 CPU)을 쓰고 여유를 두고 잡으세요.

**분당 4,000 요청 기준의 티어**(요청 하나 = 관측치 약 4개, 약 44 KB의 trace 하나). web과 worker는 이 시험에서, **ClickHouse는 [07](#07--티어별-clickhouse-자원)에서 측정**(2026-11-04, ClickHouse 26.8.22.13 노드 1개, POST당 trace 10개, trace당 API 조회 0.1. 클러스터가 아니라 노트북이므로 ClickHouse 수치는 수집 + 가벼운 조회로 읽으세요 — 긴 기간의 UI 대시보드는 측정하지 않았고 CPU 여유는 그것을 위한 것입니다). 모든 티어가 가용성을 위해 web과 worker를 2개씩, 컨테이너당 문서상 최소 2 CPU / 4 GiB를 유지하므로 small과 medium은 주로 HPA 상한과 ClickHouse에서 large와 다릅니다. 복제본당 디스크 = 일당 GiB × 보관 일수 ÷ 0.7(merge용 30 % 여유). 30일 기준:

| 티어 | 분당 요청 | web | worker | 복제본당 ClickHouse(1 shard × 3 replica) | 측정된 ClickHouse(07) |
|---|---|---|---|---|---|
| small | ≤ 1,000 | 2 × 2 CPU / 4 GiB, HPA 없음 | 2 × 2 CPU / 4 GiB, HPA 없음 | 2 CPU / 8 GiB. 디스크 하루 10.6 GiB → **30일에 약 450 GiB**(128 GiB ≈ 8일) | 0.52 CPU, 최대 anon 1.9 GiB, 하루 10.6 GiB |
| medium | ≤ 2,000 | 2 × 2 CPU / 4 GiB, HPA 최대 3 | 2 × 2 CPU / 4 GiB, HPA 최대 3 | 4 CPU / 16 GiB. 디스크 하루 21.7 GiB → **30일에 약 930 GiB**(256 GiB ≈ 8일) | 0.65 CPU, 1.7 GiB, 하루 21.7 GiB |
| large = [`values-base.yaml`](../langfuse-k8s/values-base.yaml) | 4,000 + 여유 | 2 × 2 CPU / 4 GiB, HPA 2–4, 50 % | 2 × 2 CPU / 4 GiB, HPA 2–6, 50 % | 6 CPU / 24 GiB. 디스크 하루 43.1 GiB → **30일에 약 1.8 TiB**(`values-base.yaml`의 512 GiB ≈ 8일) | 0.89 CPU, 2.2 GiB, 하루 43.1 GiB |

세 ClickHouse 크기 모두 CPU와 메모리는 측정된 수집 대비 약 4배(small)에서 7배(large)의 여유가 있습니다. 측정이 바꾸는 것은 디스크입니다. 디스크는 payload에 비례합니다. 이 trace는 관측치당 11 KB를 실으므로 prompt가 작으면 그만큼 덜 듭니다(여기서 11 KB 관측치 하나가 디스크 약 2.0 KB). blob storage는 원본 OTLP JSON을 따로 보관하며 여기서 크기를 잡지 않았습니다.

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
- **100% 수집을 KPI로 삼으려면:** blob storage와 `events_full`을 주기적으로 대조하고(이 스크립트의 방식) `rows_dropped`에 경보를 겁니다. 클라이언트의 `LANGFUSE_TIMEOUT`을 늘립니다(30초면 약 30초 동안 6회, 아래. 부하 중 효과는 06). web과 blob storage는 고가용성으로 운영합니다. 이 둘의 중단은 Langfuse가 데이터를 받기 전에 잃습니다(06: 재시도하는 로드 밸런서 뒤의 web 2개는 아무것도 잃지 않았고, Langfuse 앞의 어떤 것도 blob storage 중단은 구하지 못함). blob 객체는 적어도 대조 주기보다 오래 보관합니다.

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

따라서 ClickHouse 서버 하나에서 지점이나 프로젝트별로 저장소를 DB 단위로 나눌 수 있습니다. Langfuse 인스턴스마다 `CLICKHOUSE_DB` 하나와 사용자 하나, DB는 미리 생성, `GRANT ALL ON <db>.*`와 `SELECT ON system.parts, system.mutations`. 서버 전체 객체는 여전히 공유됩니다: 서버 자체, `system` 로그(관리자는 읽을 수 있음), settings profile과 quota. 분리 단위는 Langfuse **인스턴스**이지 한 인스턴스 안의 프로젝트가 아닙니다. 인스턴스 하나는 모든 프로젝트를 자기 DB 하나에 씁니다. Helm chart는 `clickhouse.database`로 `CLICKHOUSE_DB`를 설정합니다. 클러스터 모드(`CLICKHOUSE_CLUSTER_ENABLED=true`, `ON CLUSTER` DDL)는 DB별 사용자로는 실행하지 않았습니다(08은 관리자 사용자로 실행). 그때는 `CLUSTER` 권한도 필요합니다(이 이미지 설정의 `on_cluster_queries_require_cluster_grant`가 true).

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

### 06 — 손실 완화책: 로드 밸런서 뒤 web 2개, SDK timeout 30초, OpenTelemetry Collector

**구성**(2026-11-04 14:52–16:06 UTC, Langfuse 4.56.0 / SDK 4.17.0 / ClickHouse 26.8.22.13, OSS, worker 1개, 기존 볼륨): 03과 같은 부하와 중단 — 분당 1,200 trace × 관측치 4개(입력 10 KB + 출력 1 KB, 초당 관측치 80개), 따로 적지 않으면 POST당 trace 1개, 150초. t = 35초에 해당 구성 요소를 SIGKILL, t = 55초에 시작. 전송 = 클라이언트가 만든 관측치, 도착 = 행 수가 60초 동안 변하지 않은 뒤 `events_full`에 있는 그 실행의 서로 다른 `span_id`. HAProxy 3.2.24, OpenTelemetry Collector contrib 0.162.0. 다른 프로젝트의 kind 클러스터(약 4 CPU)가 15:05 UTC 무렵까지 같은 Docker VM에서 돌았습니다. 06은 시간이 아니라 손실 건수를 셉니다. [06-mitigations.sh](06-mitigations.sh), [06b-sdk-outage.py](06b-sdk-outage.py), [results/06-mitigations.jsonl](results/06-mitigations.jsonl), 샘플 `results/06-<scenario>-samples.tsv`, blob 대조 [results/06-reconcile.txt](results/06-reconcile.txt).

| 시나리오 | 20초 kill | 클라이언트(재시도 기한) | 전송 | 클라이언트 2xx | 도착 | 손실 | 이유 |
|---|---|---|---|---|---|---|---|
| 03, 비교용 | web | loadgen(5초) | 12,000 | 10,404 | 10,404 | 1,596 | 연결 거부가 5초 기한보다 오래 감 |
| **a** web 2개 + HAProxy, 재시도 켬([haproxy-web2.cfg](haproxy-web2.cfg)) | web-1 | loadgen(5초) | 12,000 | 12,000 | 12,000 | **0** | kill 순간 web-1에서 처리 중이던 요청 21개도 200을 받았고(클라이언트에 502 없음) 나머지는 web-2로 갔음. 클라이언트는 200만 봄(p99 3.1초), 클라이언트 재시도 없음 |
| **a** 같은 구성, 재시도 없음([haproxy-web2-noretry.cfg](haproxy-web2-noretry.cfg)) | web-1 | loadgen(5초) | 12,000 | 11,920 | 11,920 | **80** | 502 3회(web-1에서 처리 중), 503 106회: web-1이 health check 통과 전에 DNS 응답만으로 풀에 다시 들어왔고(연결 거부), web-2가 몰린 요청 속에서 3초 check를 한 번 놓침("no server available") ([로그](results/06-lb-noretry-haproxy-log.txt)) |
| **b** web 1개, 재시도 기한 30초, 송신 스레드 64개 | web | loadgen(30초) | 12,000 | 11,864 | 11,864 | **136** | exporter 규칙은 0, 1, 3, 7, 15초에 시도하고 6번째(약 28–34초)는 기한 안에 들어갈 때만 함. 중단 초반에 시작한 POST는 web이 답하기 전에 기한이 끝남. 스레드 64개가 모두 backoff 중이라 POST 대부분은 생성기 큐에서 기다렸다가 web이 돌아온 뒤 첫 시도를 했으므로 이 실행은 실제보다 좋게 나옴 |
| **b** 같은 구성, 스레드 1,024개 | web | loadgen(30초) | 12,000 | 8,944 | 10,212 | **1,788** | POST마다 자기 시계로 재시도. 재시작 순간 수백 개의 재시도가 web 하나에 한꺼번에 몰려 30초를 넘긴 것이 많았고, 클라이언트가 포기한 3,056개 중 1,268개는 저장돼 있었음 |
| **b** SDK 자체, `LANGFUSE_TIMEOUT=30`, 프로세스 1개(두 번 실행) | web | SDK(30초) | 12,000 | — | 11,580 / 11,208 | **420 / 792** | 2회차(계수): export 배치 28개 중 1개(420 span)가 30초 기한을 넘김, 큐에서 버린 span 0. 1회차 792는 배치 1개 + 큐 넘침과 맞음(아래) |
| **b** SDK 자체, 기본 5초(두 번 실행) | web | SDK(5초) | 12,000 | — | 9,996 / 9,008 | **2,004 / 2,992** | 2회차: 배치 28개 중 4개 실패(2,004 span) |
| **c** Collector, 1회 | web | loadgen → Collector(5초) | 12,000 | 12,000 | 12,000 | **0** | Collector가 큐에서 200으로 답하고 `Exporting failed. Will retry the request after interval.`을 30번 남긴 뒤 web이 돌아오자 전달(요청 2개는 두 번 전달, span당 한 행만 남음) |
| **c** Collector, 2회 | MinIO | loadgen → Collector(5초) | 12,000 | 12,000 | 10,212 | **1,788** | web이 **500**으로 답함(blob 업로드 실패). Collector는 그 요청을 버림(`Exporting failed. Dropping data.` 31회, `otelcol_exporter_send_failed_spans` = 1,788). blob storage에 없으므로 대조할 것 없음. (스레드 1,024개 실행과 도착 수가 같은 것은 우연, 별개 실행) |
| **c** Collector, 3회 | web 30–60초, Collector 36–56초 | loadgen → Collector(5초) | 12,000 | 10,544 | 10,544 | Collector 뒤 **0**, 클라이언트 **1,456** | file_storage 큐(kill 때 요청 40개 이상)가 SIGKILL 뒤에도 남아 둘이 돌아온 뒤 비워짐(큐 565 → t ≈ 89초에 0). Collector가 멈춘 동안 보낸 것은 클라이언트에서 잃음(연결 오류 1,192회) |

**a**의 첫 시도(14:38 UTC, `timeout check` 없음 = 1초, 예열 없음, HAProxy 로그 없음)는 kill 전후로 답 8,303개 중 8,239개가 503이어서 버리고 다시 실행했습니다: [results/06-lb-first-attempt.txt](results/06-lb-first-attempt.txt).

**a — 효과가 있었던 로드 밸런서 설정**(HAProxy 3.2, 다른 L7 프록시에도 같은 원리):

- `retry-on conn-failure empty-response response-timeout 502 503 504`와 `retries 3`, `option redispatch 1`: web에 닿지 못했거나 처리 중에 web이 죽은 요청을 다른 복제본으로 보냅니다. 손실 0과 80의 차이가 이것입니다.
- `option http-buffer-request`와 가장 큰 POST보다 큰 `tune.bufsize`(여기서 1 MiB): HAProxy가 본문 전체를 들고 있어야 다시 보낼 수 있습니다. 버퍼보다 큰 요청은 재시도되지 않으므로(HAProxy 문서) SDK 배치(최대 512 span × 11 KB ≈ 5.6 MB)에는 더 큰 버퍼나 더 작은 배치가 필요합니다 — SDK 배치로는 실행하지 않았습니다.
- health check `GET /api/public/health` 1초마다, `fall 2 rise 2`, **`timeout check 3s`**: 바쁜 web은 check에 1초 넘게 걸렸습니다.
- Docker DNS의 `resolvers`: kill된 컨테이너는 이름이 풀리지 않아 곧바로 풀에서 빠지고, 재시작하면 check 통과 *전에* DNS 응답만으로 다시 들어옵니다. 그 구간은 재시도만 덮습니다.
- 실행하지 않음: nginx, Kubernetes ingress. nginx는 한 번 보낸 POST를 `proxy_next_upstream … non_idempotent` 없이는 다음 upstream으로 넘기지 않고(nginx 문서), Kubernetes Service(kube-proxy)는 아예 재시도하지 않습니다.

**b — `LANGFUSE_TIMEOUT=30`이 하는 일과 못 하는 일.** SDK의 `LangfuseSpanProcessor`는 OpenTelemetry `BatchSpanProcessor`입니다(`langfuse/_client/span_processor.py:98, 197-199`). exporter 스레드 하나, 가득 차면 span을 버리는 `OTEL_BSP_MAX_QUEUE_SIZE` 크기의 큐(기본 2,048, `opentelemetry/sdk/trace/export/__init__.py:44`; 버리는 곳 `opentelemetry/sdk/_shared_internal/__init__.py:199-203`), `flush_interval`(5초)마다 `flush_at` span씩 배치(초당 80 span이면 배치당 약 400 span, 150초에 28개). timeout은 배치 *하나*의 재시도 기한입니다. 그 배치가 재시도하는 동안 스레드가 막혀 큐가 찹니다. 그래서:

- 배치는 web이 기한 안에 답해야 살아남습니다. 시도는 0, 1, 3, 7, 15초(들어가면 약 28–34초)이므로 30초는 약 15초를 확실히, 최대 30초를 운에 따라 덮습니다. 여기서 클라이언트가 본 중단은 약 20초 + web 기동 시간이었습니다.
- 배치가 약 30초 재시도하는 동안 초당 2,048 / 30 ≈ 68 span보다 많이 만드는 프로세스는 큐가 넘칩니다. 초당 80 span인 1회차가 그랬을 가능성이 큽니다(배치 하나 약 430 대비 792 손실). 프로세스마다 `OTEL_BSP_MAX_QUEUE_SIZE`를 *초당 span × 기한* 이상으로 올리세요(메모리 ≈ 큐 × span 크기, 여기서 11 KB).
- SDK 자체 경고(`Queue full, dropping Span.`, `Failed to export spans batch due to timeout…`)는 OpenTelemetry `DuplicateFilter`가 중복을 지우므로(`_shared_internal/__init__.py:33, 76`) 로그는 적게 셉니다. 06b-sdk-outage.py는 `BatchProcessor.emit`과 `OTLPSpanExporter.export`를 감싸서 셉니다.
- 각자 재시도하는 프로세스가 많으면(스레드 1,024개 실행) 오히려 나빠질 수 있습니다. web이 돌아올 때 재시도가 한꺼번에 몰립니다.

**c — Collector 설정**([docker-compose.otelcol.yml](docker-compose.otelcol.yml), 정확한 설정 [otelcol.yaml](otelcol.yaml)): `otlp` receiver(HTTP :4318) → `otlphttp` exporter, `http://langfuse-web:3000/api/public/otel`로 `basicauth`(프로젝트 키), `timeout: 30s`, `retry_on_failure`(1초에서 두 배씩 30초까지, `max_elapsed_time: 300s`), 이름 있는 볼륨의 `storage: file_storage/queue`를 쓰는 `sending_queue`, `num_consumers: 10`, `queue_size: 100000`. batch processor는 없음(요청 하나 들어오면 하나 나감, blob 수 비교를 위해). 실습 한정: 새 볼륨에 쓰기 위해 컨테이너를 user 0으로 실행.

- **Collector는 500을 재시도하나? 아니요.** `otlphttp`는 429, 502, 503, 504와 네트워크 오류만 재시도하고, 다른 상태 코드는 모두 `consumererror.NewPermanent`로 돌려 버립니다(opentelemetry-collector v0.162.0 `exporter/otlphttpexporter/otlp.go:233-235, 264-277`). `retry_on_failure`와 `sending_queue`는 재시도 가능한 오류에만 작동하고, 어떤 상태 코드를 재시도 가능하게 바꾸는 exporter 설정은 없습니다. Langfuse는 blob 업로드 실패에 500, S3 `SlowDown`에만 503으로 답하므로(01) blob storage 중단은 SDK에서와 똑같이 Collector에서 잃습니다(03: 1,524 손실). 이 틈은 고가용성 blob storage로만 막힙니다.
- 큐는 Collector의 SIGKILL을 견뎠습니다(3회). `file_storage`는 기본적으로 fsync하지 않으므로 프로세스 kill이 아닌 호스트 장애에서는 끝부분을 잃을 수 있습니다.
- Collector는 클라이언트가 닿아야 하는 새 hop이 됩니다. 그 중단은 클라이언트 쪽 손실입니다(3회: 1,456). 노드별 agent로 두거나 로드 밸런서 뒤에 여러 개를 두세요.

**06에서 권할 것:** **다른 복제본으로 POST를 재시도하는** 로드 밸런서 뒤의 web 2개 이상(손실 0), web 중단과 Langfuse 재시작에 대비한 파일 큐 Collector(손실 0, Collector 자체도 고가용성), `LANGFUSE_TIMEOUT=30`은 더 큰 `OTEL_BSP_MAX_QUEUE_SIZE`와 함께만 — 혼자서는 여기서 손실을 2,004–2,992에서 420–792로 줄였을 뿐 0으로 만들지 못했습니다. 그리고 고가용성 blob storage: 셋 중 어느 것도 blob storage 중단에는 도움이 되지 않습니다.

### 07 — 티어별 ClickHouse 자원

**구성**(2026-11-04 15:28–15:43 UTC, Langfuse 4.56.0 OSS, 이전 시험 데이터 약 820 MiB가 있는 스택 기존 볼륨의 ClickHouse 26.8.22.13, web + worker 각 2 CPU(오버레이 `cpu2`, 02와 같음), worker 1개, ClickHouse에는 CPU·메모리 제한 없음, Docker VM 12 CPU / 16 GiB, kind 클러스터 없음). 단계 전에 부하 없이 60초(idle). 이어서 단계마다 분당 RATE trace × 관측치 4개(입력 10 KB + 출력 1 KB) 240초, **OTLP POST당 trace 10개**(02에서 통과한 방식), **trace당 조회 0.1**(trace 상세와 관측치 목록 번갈아), 송신 스레드 128개. ClickHouse 컨테이너만 측정: 부하 시작부터 행이 안정된 뒤 20초까지(272초)의 cgroup v2 `cpu.stat` `usage_usec`을 부하 1분당으로, 2초마다 `memory.current`, `anon`(`memory.stat`), ClickHouse `MemoryTracking`, insert·새 part·merge는 `system.query_log`와 `system.part_log`, `default` DB active part의 `bytes_on_disk` 증가. 샘플러 자체의 쿼리는 idle 수치에 들어 있습니다. [07-clickhouse-tiers.sh](07-clickhouse-tiers.sh), [results/07-clickhouse-tiers.jsonl](results/07-clickhouse-tiers.jsonl), 샘플 `results/07-<rate>-samples.tsv`.

| ClickHouse, 노드 1개 | idle | 분당 1,000 trace | 분당 2,000 trace | 분당 4,000 trace |
|---|---|---|---|---|
| 분당 CPU-초(= 코어) | 12.7 (0.21) | 31.4 (0.52) | 38.8 (0.65) | 53.1 (0.89) |
| … idle 제외 | — | 17.0 (0.28) | 24.4 (0.41) | 38.7 (0.65) |
| 최대 `memory.current` / `anon` / `MemoryTracking` | 2,031 / 820 / 502 MiB | 3,246 / 1,904 / 1,685 MiB | 3,071 / 1,790 / 1,351 MiB | 3,833 / 2,296 / 1,489 MiB |
| 초당 INSERT 쿼리 / 새 part | 0 / 0 | 1.0 / 1.9 | 0.9 / 1.9 | 1.0 / 1.9 |
| 단계 중 merge · 최대 동시 merge · `events_full` 최대 active part | 0 · 1 · 12 | 94 · 2 · 18 | 92 · 2 · 16 | 94 · 2 · 19 |
| 디스크 증가 시간당 → 일당 | — | 0.44 → **10.6 GiB** | 0.90 → **21.7 GiB** | 1.80 → **43.1 GiB** |
| 관측치당 디스크 | — | 1,981 B | 2,019 B | 2,008 B |
| 조회: 건수, p50 / p95 | — | 391, 40 / 311 ms | 783, 42 / 807 ms | 1,564, 35 / 771 ms |
| 수집 지연 p95, 손실 | — | 1.09초, 0 | 1.65초, 0 | 1.21초, 0 |
| 시작 시점 다른 컨테이너 CPU | 33 % | 37 % | 15 % | 17 % |

- **insert와 part는 부하에 따라 늘지 않습니다.** worker의 writer는 양과 무관하게 `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS`(1초)마다 한 번 flush하므로(01) ClickHouse는 모든 부하에서 초당 약 1 INSERT, 약 1.9개의 새 part(`events_full`과 materialized view `events_core`), 단계당 약 93번의 merge, active part 최대 19개를 봅니다. part 한도와는 거리가 멉니다. 느는 것은 바이트입니다. 분당 1,000 trace가 늘 때마다 약 0.12–0.13 CPU.
- **메모리는 대부분 고정입니다.** 최대 `anon`은 모든 부하에서 1.7–2.2 GiB, idle에서 0.8 GiB. `memory.current`의 나머지는 page cache입니다. ClickHouse는 보이는 RAM(여기서 16 GiB)에 맞춰 캐시 크기를 잡으므로 8 GiB 복제본은 캐시에 덜 씁니다. 이 조회 혼합이 더하는 양은 작습니다.
- **디스크는 관측치당 약 2.0 KB**(입력 + 출력 11 KB, 압축 후, `events_full` + `events_core`): 일당 ≈ 분당 trace × 4 × 1,440 × 2.0 KB, **복제본마다** — 복제본은 모두 전체 사본을 가집니다. blob storage는 원본 OTLP JSON을 따로 보관합니다(여기서 측정하지 않음).
- **제안한 크기가 맞나?** CPU와 메모리는 맞습니다. small(2 CPU / 8 GiB)은 분당 1,000 이하에서 약 0.5 CPU와 약 1.9 GiB, medium(4 CPU / 16 GiB)은 분당 2,000 이하에서 약 0.65 CPU와 약 1.7 GiB — 수집만이면 small에도 들어가고 나머지는 측정하지 않은 UI·분석 쿼리를 위한 여유입니다. large(6 CPU / 24 GiB)는 분당 4,000에서 약 0.9 CPU와 약 2.2 GiB. **디스크는 맞지 않습니다.** 128 / 256 / 512 GiB는 분당 1,000 / 2,000 / 4,000 trace에서 약 12일, merge용으로 30 %를 비워 두면 약 8일이면 찹니다. 디스크는 필요한 보관 기간으로 정하세요.
- 1 shard × 3 replica에서는 복제본마다 모든 part를 쓰거나 받아 오고 직접 merge하므로 복제본당 CPU, 메모리, 디스크 ≈ 위의 단일 노드 수치입니다. 조회는 클라이언트가 모든 복제본에 닿을 때만 나뉩니다(08).
- 노트북의 한계: 노드 하나, 복제 트래픽 없음, 부하 생성기가 같은 호스트, 볼륨에 이전 데이터. CPU-초는 ClickHouse 자신의 일만 세므로 다른 부하로 크게 부풀지 않지만 CPU 속도에는 좌우됩니다.

### 08 — ClickHouse 1 shard × 3 replica

**구성**(2026-11-04 15:44–15:57 UTC): 새 볼륨의 별도 compose 프로젝트 `langfuse-hols-v4ch3`(기본 파일 + [docker-compose.ch3.yml](docker-compose.ch3.yml)). 그동안 v4 스택은 멈춰 두었고(같은 호스트 포트) 끝나고 다시 띄웠으며, 그 볼륨은 건드리지 않았습니다. `clickhouse-server:26.8.22.13` 복제본 셋 `clickhouse`, `clickhouse-2`, `clickhouse-3`이 클러스터 `langfuse`(shard 1개, `internal_replication`, macro는 환경 변수에서: [ch3-cluster.xml](ch3-cluster.xml))에 있고 `clickhouse-keeper:26.8.22.13` 하나([ch3-keeper.xml](ch3-keeper.xml), 운영에선 셋). Langfuse 4.56.0 OSS, `CLICKHOUSE_CLUSTER_ENABLED=true`, `CLICKHOUSE_CLUSTER_NAME=langfuse`, `CLICKHOUSE_MIGRATION_URL=clickhouse://clickhouse:9000`. 부하는 03과 같음(분당 1,200 trace × 관측치 4개, 10 KB / 1 KB, POST당 trace 1개, 150초, SDK 재시도 5초). 35초에 SIGKILL, 55초에 시작. [08-clickhouse-cluster.sh](08-clickhouse-cluster.sh), [results/08-cluster.txt](results/08-cluster.txt), [results/08-cluster.jsonl](results/08-cluster.jsonl), [results/08-reconcile.txt](results/08-reconcile.txt), 샘플 `results/08-<step>-samples.tsv`.

**Migration.** 첫 `compose up` 45초 뒤 정상, 막힌 곳 없음. 클러스터 이름이 `default`가 아니면 migration 스크립트가 canonical migration을 그 이름으로 렌더링합니다(`prepare-migrations.mjs render`, `/app/packages/shared/clickhouse/scripts/up.sh:56-114`). 이미지에 든 `migrations/clustered/` 파일은 `ON CLUSTER default`가 박혀 있습니다. 세 복제본 각각: `ReplicatedReplacingMergeTree` 12개, `ReplicatedMergeTree` 1개(`schema_migrations`), materialized view 1개, view 3개. `schema_migrations` 최신 51, dirty 아님. `events_full`은 `ReplicatedReplacingMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}', event_ts, is_deleted)`. `system.replicas`: 전체 3, 활성 3.

**Langfuse가 연결하는 복제본: 하나.** `CLICKHOUSE_URL`은 URL 하나이고(`CLICKHOUSE_URL: zod.url()`, `@langfuse/shared/dist/src/env.js:132`) `CLICKHOUSE_MIGRATION_URL`도 그렇습니다. 처음 두 실행에서 INSERT는 모두 `clickhouse`로 갔고(복제본별 initial INSERT 쿼리 150 / 0 / 0, 123 / 0 / 0) 나머지 둘은 part를 받아 왔습니다.

| 20초 kill | `CLICKHOUSE_URL` | 전송 = 수락 | 도착 | 손실 | 복제본 1 / 2 / 3의 INSERT | kill된 복제본 따라잡기 | [03c-reconcile.sh](03c-reconcile.sh) 뒤 |
|---|---|---|---|---|---|---|---|
| `clickhouse-2`(URL에 없음) | `http://clickhouse:8123` | 12,000 | 12,000 | **0** | 150 / 0 / 0 | 시작 후 4초 안(첫 샘플) | — |
| `clickhouse`(URL) | `http://clickhouse:8123` | 12,000 | 10,396 | **1,604**(`Max attempts reached` 20회) | 123 / 0 / 0 | —(그동안 어느 복제본도 행을 받지 못함) | 모자란 파일 401개 → 재투입 → 셋 모두 **12,000** |
| `clickhouse` | `http://chlb:8123`, 셋 앞의 HAProxy([haproxy-ch3.cfg](haproxy-ch3.cfg)) | 12,000 | 12,000 | **0** | 45 / 49 / 52 | 5초 안 | — |

- **복제본은 데이터를 지키지만 수집 경로는 지키지 않습니다.** Langfuse가 장애 조치되는 무언가를 거쳐 닿을 때만 다릅니다. `CLICKHOUSE_URL`에 호스트가 하나면 그 호스트의 중단은 단일 노드 03과 같습니다(거기서 1,972, 여기서 1,604 손실). writer가 3회 뒤 버리고, 원본 이벤트는 blob storage에 남고, 대조로 되살립니다.
- **`CLICKHOUSE_URL`을 로드 밸런서로 하자 손실이 없었습니다.** HAProxy, `GET /ping` check 1초마다(`fall 2`), `retry-on conn-failure empty-response 502 503 504`, `option redispatch`, 요청 버퍼링. insert는 세 복제본에 나뉘었습니다. Kubernetes에서는 readiness probe가 있는 전체 복제본 대상 Service가 같은 역할입니다 — 여기서 실행하지 않았고, kube-proxy는 재시도하지 않으므로 writer의 3회 시도가 장애 감지 시간보다 길어야 합니다.
- 시험하지 않음: INSERT는 복제본 하나가 쓰면 확인됩니다(`insert_quorum` 없음). 다른 복제본이 받아 가기 전에 그 복제본의 디스크를 잃으면 그 행은 blob storage에만 있습니다. 로드 밸런서를 거친 쓰기 직후 조회는 몇 초 뒤처진 복제본에 닿을 수 있습니다(여기서 따라잡기 5초 이하). Keeper 중단(여기선 Keeper 하나. Keeper가 없으면 Replicated 테이블이 읽기 전용이 된다고 ClickHouse 문서에 있음), Keeper 3노드, 관리자가 아닌 사용자의 `ON CLUSTER`(04: `CLUSTER` 권한 필요), Helm chart의 클러스터 모드.

### 하지 못한 것과 이유

- 02는 다른 프로젝트의 컨테이너가 같은 Docker VM을 쓰는 중에 실행했습니다. 단계별 `foreign_cpu_pct`를 보세요. 첫 시도(`results/02-sizing-contended.*`)는 다른 부하가 약 6 CPU를 쓰는 중이어서 버렸습니다.
- web 확장은 가용성(06a)으로만 실행했고 처리량으로는 하지 않았습니다. HAProxy 뒤의 web 2개를 02의 부하 사다리에 올리지 않았습니다.
- 06에서 실행하지 않은 것: nginx, Kubernetes ingress나 Service, batch processor를 둔 Collector나 Collector 여러 개, 기본값보다 큰 `OTEL_BSP_MAX_QUEUE_SIZE`.
- 실제 클라우드 object store가 아닙니다. S3 호출 수는 MinIO 기준이고 클라우드 사업자의 요청 빈도 제한은 시험하지 않았습니다. `SlowDown` → 503 경로는 소스로만 확인했습니다.
- ClickHouse 클러스터 모드는 Compose로 실행했고(08) Helm chart로는 하지 않았습니다. Keeper는 노드 하나였고 kill하지 않았습니다. ClickHouse의 UI 조회 부하(07)는 측정하지 않았습니다.
