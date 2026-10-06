# Langfuse-on-ClickHouse Enterprise Workshop — Full Run Log & Blog Source

A complete, captured end-to-end run of every lab in [`labs/langfuse-ee/`](./README.md): the OSS track (01–04) and the full Enterprise track (05–11), on the shared stack in [`_base/`](../../../_base/README.md). This is the raw material for a tech blog: real commands, real output, and the findings that came out of running it.

> Language note: the run log below is in English (console output is language-neutral). A Korean blog outline (한국어 블로그 아웃라인) is at the end.

---

## TL;DR

- Self-hosted **Langfuse v4.48.0** stores every observation in two new **ClickHouse 26.8.15.10** tables, `events_full` and `events_core`; scores stay in `scores`. We stood the stack up, sent traces with Python SDK 4.16.0, and ran cost, latency and quality analytics straight on ClickHouse — with no joins, because v4 puts the trace attributes on every observation row.
- We then activated an **Enterprise license** and exercised the EE entitlements end to end. The highlight is **server-side data masking, *proven* in ClickHouse with SQL**, ending in a PASS/FAIL verdict that was itself tested against eight planted cases. The other one is a **Parquet export ↔ ClickHouse `s3()` round-trip**.
- The optional real model calls go to **Anthropic `claude-haiku-4-5`**, traced by OpenTelemetry and priced by Langfuse.
- Main findings, all from this run:
  - v4 writes somewhere else, so v3-era SQL returns nothing.
  - Cost depends on the usage key names.
  - The masking proof needs a positive control.
  - The Parquet drift seen on v3.197.1 is gone on 4.48.0.

## Environment

| Component | Version / detail |
|---|---|
| Host | macOS (Darwin 25.6), Docker Desktop |
| Docker Engine / Compose | 29.8.1 / v5.5.1 |
| Langfuse (web + worker) | **v4.48.0** (`langfuse/langfuse:4.48.0`, `langfuse/langfuse-worker:4.48.0`), default `events_only` write mode |
| ClickHouse | **26.8.15.10** (LTS) |
| Postgres / Redis / MinIO | 17.11 / 7.2.16 / `cgr.dev/chainguard/minio@sha256:4692462f…` (RELEASE.2026-09-22T19-25-18Z) |
| Masking sidecar | `python:3.12.14-slim` (stdlib only) |
| Python SDK | `langfuse` **4.16.0** on Python 3.12.14 (OpenTelemetry-native) |
| Real model calls (optional) | `anthropic` 1.11.0 + `opentelemetry-instrumentation-anthropic` 0.62.4, model `claude-haiku-4-5` |
| Run date | 2026-10-02 KST. Timestamps below are UTC, 2026-10-01 23:22–23:26 |

Pins and the reason for each are in [`STATUS.md`](../../../STATUS.md).

## Run summary

| Lab | Feature | Result |
|---|---|---|
| 01 | Stack up (6 containers) | ✅ healthy; `/api/public/health` → `{"status":"OK","version":"4.48.0"}`; `check.sh` all PASS, ClickHouse migrations 50/50 |
| 02 | Generate traces (SDK) | ✅ 40 traces offline, plus 5 with real `claude-haiku-4-5` calls |
| 03 | Explore the ClickHouse backend | ✅ data in `events_full` / `events_core` (137 rows each), `scores` 78; v3 `traces` / `observations` **0** |
| 04 | Analytics on ClickHouse | ✅ cost / latency p95 / errors / tier / quality / leaderboard / trend / sessions, with no joins |
| 05 | Activate Enterprise | ✅ Instance Management API → HTTP 200 |
| 06 | RBAC & SCIM | ✅ org + project + 2 SCIM users + project-level role override |
| 07 | Data retention + audit | ✅ 14-day retention; audit log shows every lab-06 action |
| 08 | **Server-side data masking** | ✅ **verdict PASS**: 24 masked rows, 0 leaks, 108 redactions; the verdict FAILs on an empty table and on 6 other planted cases |
| 09 | Protected prompt labels | ✅ v1→v2 label move; prompts in Postgres; audited |
| 10 | Instance governance | ✅ UI + org-creator vars injected and verified |
| 11 | Parquet export ↔ ClickHouse | ✅ **`fileType: PARQUET` accepted** with the `OBSERVATIONS_V2` source; `s3()` round-trip **182 == 182** |

---

## Reset — clean slate

```console
$ _base/bin/down.sh --purge
▶ Stopping stack and DELETING all data volumes…
 …
✅ Stack down, volumes removed.
```

## Lab 01 — Deploy the stack (OSS)

```console
$ ./01-up.sh
▶ No _base/.env found — creating one from _base/.env.example (edit the # CHANGEME values for prod).
▶ Starting Langfuse stack in OSS mode (postgres · clickhouse · redis · minio · web · worker)…
 …
 Container langfuse-hols-langfuse-web-1 Started
▶ Waiting for langfuse-web to become healthy (first boot runs DB + ClickHouse migrations, ~2-3 min)…
..✅ Langfuse is up after ~15s.

────────────────────────────────────────────────────────────
  Langfuse UI      http://localhost:3000
  Login            admin@example.com / workshop-admin-pw
  Project          LLM Observability
  API public key   pk-lf-workshop-public
  MinIO console    http://localhost:9091   (minio / miniosecret)
  ClickHouse HTTP  http://localhost:8123   (clickhouse / clickhouse)
────────────────────────────────────────────────────────────
```

```console
$ _base/bin/check.sh
PASS  container langfuse-web running
PASS  container langfuse-worker running
PASS  container postgres running, healthy
PASS  container clickhouse running, healthy
PASS  container redis running, healthy
PASS  container minio running, healthy
PASS  web http://localhost:3000/api/public/health -> 200 (Langfuse 4.48.0)
PASS  worker http://localhost:3030/api/health -> 200
PASS  ClickHouse migrations finished (applied 50, shipped 50, dirty 0)
PASS  SDK keys accepted (http://localhost:3000/api/public/projects -> 200)
SKIP  masking sidecar
     not running -- only lab 08 (docker-compose.masking.yml) starts it

1 check(s) skipped -- a skip is not a pass.
stack is ready.
```

The compose file uses **headless initialization** (`LANGFUSE_INIT_*`) to create the first org, project, user and API keys on boot, so data can flow before anyone opens the UI.

`check.sh` checks more than "the server answers". It compares the latest row of ClickHouse's `schema_migrations` with the highest migration number shipped in the web image. v4.48.0 ships 50; v3.197.1 shipped 34.

## Lab 02 — Generate traces via the Python SDK

```console
$ python 02-generate-traces.py
✓ Connected. Generating 40 traces (offline / simulated)…
  …10/40 traces
  …20/40 traces
  …30/40 traces
  …40/40 traces
✓ Done. Open http://localhost:3000 → Tracing → Observations.
```

With `ANTHROPIC_API_KEY` set, the same script makes real calls:

```console
$ python 02-generate-traces.py 5
✓ Connected. Generating 5 traces (REAL Anthropic calls (claude-haiku-4-5))…
✓ Done. Open http://localhost:3000 → Tracing → Observations.
```

**The trace tree.** Each trace is a nested observation tree: a `support-request` root span, then a `retrieve-context` span, then an `answer-generation` generation, and occasionally a `self-check`. Every trace carries scores.

**SDK v4 changes.**
- SDK v4 has no `update_current_trace()`. The generator wraps the work in `propagate_attributes(trace_name=…, user_id=…, session_id=…, tags=…, metadata=…)`, which writes those attributes onto every observation it creates.
- Usage is sent as `{"input": …, "output": …}`, the keys Langfuse prices by.

**The real path.** Real calls use the official `anthropic` SDK. `opentelemetry-instrumentation-anthropic` turns each call into a GENERATION span, and v4's default span filter keeps it because it carries `gen_ai.*` attributes. Measured after the run, the instrumented calls were:
- 65 rows with scope `opentelemetry.instrumentation.anthropic`
- model `claude-haiku-4-5-20251001` (the dated ID the API returns)
- priced by Langfuse at $0.0137

## Lab 03 — Explore the ClickHouse backend

```console
$ docker exec -i langfuse-hols-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse \
    --multiquery < 03-clickhouse-explore.sql
```

Tables Langfuse v4 created:

```
analytics_observations        View
analytics_scores              View
analytics_traces              View
blob_storage_file_log         ReplacingMergeTree
dataset_run_items_rmt         ReplacingMergeTree
events_core                   ReplacingMergeTree
events_core_mv                MaterializedView
events_full                   ReplacingMergeTree
observations                  ReplacingMergeTree
observations_batch_staging    ReplacingMergeTree
observations_pid_tid_sorting  ReplacingMergeTree
schema_migrations             MergeTree
scores                        ReplacingMergeTree
traces                        ReplacingMergeTree
```

Engine, partition and sort key for the tables that hold data:

```
events_core  ReplacingMergeTree  toYYYYMM(start_time)  project_id, toStartOfMinute(start_time), xxHash32(trace_id), span_id, start_time
events_full  ReplacingMergeTree  toYYYYMM(start_time)  project_id, toStartOfMinute(start_time), xxHash32(trace_id), span_id, start_time
scores       ReplacingMergeTree  toYYYYMM(timestamp)   project_id, toDate(timestamp), name, id
```

Row counts. This is **the v4 evidence**: the v3 tables still exist, and stay empty.

```
events_full         137
events_core         137
traces (v3)           0
observations (v3)     0
scores               78
```

The latest traces are read from their root rows (`is_app_root`). Trace attributes sit on every observation row:

```
af4d80e6…  support-request  user_007  sess_user_007_7  ['env:production','feature:search-assist','tier:enterprise']
d2d76a95…  support-request  user_008  sess_user_008_7  ['env:production','feature:troubleshooting','tier:pro']
…
SPAN        support-request    root=true
SPAN        retrieve-context   root=false
GENERATION  answer-generation  root=false  gpt-4o-mini  {'input':761,'output':286,'total':1047}  {'input':0.00011415,'output':0.0001716,'total':0.00028575}
```

**Columns.**
- `events_core` has the same columns as `events_full`, with truncated `input` / `output`. The materialized view `events_core_mv` fills it.
- `total_cost` is an `ALIAS` of `cost_details['total']`, and `calculated_*_cost` are `MATERIALIZED` from `cost_details`.
- Metadata is two parallel arrays, `metadata_names` / `metadata_values`.

**ReplacingMergeTree.** Raw rows and `FINAL` agreed in this run: **137 = 137**. On v3.197.1 the `traces` table showed 41 raw rows for 40 traces. Langfuse describes the v4 events table as "mostly immutable", which fits. The lab still reads with `FINAL` + `is_deleted = 0`, because retention deletes and updates do create row versions.

## Lab 04 — Analytics directly on ClickHouse

```console
$ docker exec -i langfuse-hols-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse \
    --multiquery < 04-clickhouse-analytics.sql
```

Every query reads `events_core FINAL`. v3 needed a traces↔observations join to put a user or a tier next to a generation. v4 does not: the attributes are already on the row.

**1) Spend & tokens by model** — `sum()` over the `usage_details` map and `total_cost`:

| model | calls | input_tok | output_tok | total_cost_usd | avg_cost/call |
|---|--:|--:|--:|--:|--:|
| gpt-4o | 9 | 5,785 | 2,547 | 0.039932 | 0.004437 |
| claude-haiku-4-5 | 15 | 12,360 | 3,330 | 0.029010 | 0.001934 |
| gpt-4o-mini | 33 | 15,417 | 3,682 | 0.004522 | 0.000137 |

**2) Latency p50/p95/p99 per model** — `quantile()` over `dateDiff('millisecond', start_time, end_time)`:

| model | calls | avg_ms | p50 | p95 | p99 |
|---|--:|--:|--:|--:|--:|
| gpt-4o | 9 | 792 | 724 | 1,335.40 | 1,405.48 |
| claude-haiku-4-5 | 15 | 532 | 543 | 805.30 | 817.06 |
| gpt-4o-mini | 33 | 228 | 184 | 524.40 | 553.88 |

**3) Error rate per model** — `countIf(level = 'ERROR')`:

| model | calls | errors | error_pct |
|---|--:|--:|--:|
| gpt-4o | 9 | 1 | 11.11 |
| claude-haiku-4-5 | 15 | 1 | 6.67 |
| gpt-4o-mini | 33 | 0 | 0 |

**4) Cost by customer tier** — the tier comes from the row's own tags, with no join:

| tier | traces | cost_usd | cost_per_trace |
|---|--:|--:|--:|
| free | 15 | 0.029991 | 0.001999 |
| pro | 13 | 0.028379 | 0.002183 |
| enterprise | 12 | 0.015094 | 0.001258 |

**5) Satisfaction from scores.**
- Thumbs-up by tier: enterprise 75%, free 73.3%, pro 84.6%.
- Overall: thumbs votes **40**, thumbs-up **77.5%**, average grounding **0.808**.

**6) Per-user spend leaderboard** (top rows):

| user | sessions | requests | cost |
|---|--:|--:|--:|
| `user_005` | 4 | 5 | $0.0135 |
| `user_011` | 4 | 4 | $0.0124 |
| `user_012` | 3 | 3 | $0.0106 |

**7) Daily trend:** `2026-10-01` (UTC) → 40 traces, 12 unique users, $0.073464.

**8) Session depth:** 32 sessions with 1 turn, 4 sessions with 2 turns.

---

## Lab 05 — Activate Enterprise

```console
$ ./05-ee-activate.sh
▶ Re-deploying with the Enterprise overlay (license key + admin API)…
▶ Waiting for langfuse-web to come back…
. ready.
▶ Verifying Enterprise activation via the Instance Management API…
✅ Enterprise active. Admin API reachable. Current organizations:
{"organizations":[{"id":"ch-workshop","name":"ClickHouse Workshop","createdAt":"2026-10-01T23:22:33.651Z","metadata":{},"projects":[{"id":"llm-observability","name":"LLM Observability", …}]}]}
```

The overlay injects `LANGFUSE_EE_LICENSE_KEY` into **both** containers, plus `ADMIN_API_KEY`. `/api/admin/organizations` only answers HTTP 200 when a valid license is present. CI checks that both containers get the key in every overlay set.

## Lab 06 — RBAC & SCIM (full self-service admin chain)

```console
$ ./06-ee-rbac-scim.sh
════ 1. Create an organization (Instance Management API, Bearer auth) ════
  org id = cmuq5uv6f0002pg07oduk61r1
════ 2. Mint an organization-scoped API key ════
  org public key = pk-lf-4e4bddb2-…            (secret not printed)
════ 3. Create a project under the org ════
  project id = cmuq5uvc40008pg07e5qs643d
════ 4. Mint a project API key ════
  project public key = pk-lf-7bb1fd6d-…
════ 5. SCIM: provision two users (as an IdP like Okta/Entra would) ════
  alice id = cmuq5uvhs…   bob id = cmuq5uviw…
════ 6. Assign ORGANIZATION-level roles ════
  alice=MEMBER (org), bob=VIEWER (org)
════ 7. PROJECT-LEVEL role override (Enterprise feature) ════
  bob=ADMIN (project acme-prod) — overrides his org-level VIEWER role
════ 8. Read back the resulting access matrix ════
── organization memberships ──
[ {"role":"MEMBER","email":"alice@acme.test", …}, {"role":"VIEWER","email":"bob@acme.test", …} ]
── acme-prod project memberships ──
[ {"role":"ADMIN","email":"bob@acme.test", …} ]
```

The EE feature is the last line: **Bob is `VIEWER` org-wide but `ADMIN` on one project**. The whole chain is provisioned through APIs, the way an IdP, Terraform or a CI pipeline would do it.

## Lab 07 — Data Retention + Audit Logs

```console
$ ./07-ee-audit-retention.sh
════════════════ A) Data Retention ════════════════
▶ Setting 14-day retention on project 'llm-observability'…
{ "id": "llm-observability", "name": "LLM Observability", "retentionDays": 14 }

════════════════ B) Audit Logs ════════════════
  table = audit_logs           (stored in Postgres, snake_case columns)
▶ Most recent audit events:
       created_at        | action | resource_type |  actor
-------------------------+--------+---------------+-----------
 2026-10-01 23:23:59.722 | create | apiKey        | ADMIN_KEY
 2026-10-01 23:23:59.39  | create | orgMembership | cmuq5uvas…
 2026-10-01 23:23:59.348 | create | orgMembership | cmuq5uvas…
 2026-10-01 23:23:59.298 | create | apiKey        | ORG_KEY
 2026-10-01 23:23:59.096 | create | apiKey        | ADMIN_KEY
 2026-10-01 23:23:58.94  | create | organization  | ADMIN_KEY
```

A non-zero retention value requires the data-retention entitlement. A nightly worker then deletes event data older than the window. The audit log is the immutable who / what / when, and it captured **every action lab 06 performed**.

---

## Lab 08 — Server-Side Data Masking ⭐ (proven in ClickHouse)

The flagship demo works in three steps:
1. A small stdlib masking sidecar is wired to the worker.
2. Langfuse POSTs each OTLP-ingested event to it, and the sidecar redacts secrets **before** the event is persisted.
3. A SQL scan of ClickHouse then proves the raw secrets never landed.

On v4 that scan has to read `events_full`, the table with the full payloads. `events_core` truncates them.

```console
$ ./08-ee-data-masking.sh
▶ Bringing up the masking sidecar + wiring the worker to it…
▶ Sending PII-laden traces (secrets embedded in input/output/metadata)…
  (using interpreter: .venv/bin/python)
✓ Connected. Sending 12 PII-laden traces to the OTLP endpoint…
▶ Letting the worker ingest + mask (async)…
▶ Verifying against ClickHouse (events_full) — raw secrets should be GONE, [REDACTED_*] present:
pii-demo rows present	24
── events_full: raw-secret leak counts (want all 0) ──
0	0	0	0
── pii-demo rows carrying a [REDACTED_*] placeholder (want > 0) ──
24	24
── sample masked observation payloads ──
name:            support-request
input_sample:    {"question": "My card [REDACTED_CC] was charged twice, please refund."}
output_sample:   {"answer": "I've opened a refund for the card ending in the number you sent ([REDACTED_CC])."}
meta_raw_email:  [REDACTED_EMAIL]
meta_raw_rrn:    [REDACTED_KR_RRN]
…
verdict	PASS	24	24	0
✅ MASKING VERDICT: PASS.
```

```console
$ docker logs langfuse-hols-masking-1
masking-callback listening on :3100 (POST /mask, GET /health)
[mask] project=llm-observability redactions=108
```

**Why the verdict matters on v4.** In v4's default mode the v3 `traces` / `observations` tables receive no rows at all. A leak check pointed at them returns `0` and "passes" without having looked at any data.

The verification therefore ends in one `verdict` row. It is `PASS` only if all three hold:
- pii-demo rows exist
- `[REDACTED_` placeholders exist
- every leak count is 0

The script exits 1 on `FAIL`. `--selftest` proves the empty-table case fails:

```console
$ ./08-ee-data-masking.sh --selftest
▶ Running 08-verify-masking.sql against an EMPTY events_full (expect verdict FAIL)…
verdict	FAIL	0	0	0
✅ Selftest OK: the empty table produced verdict FAIL, so a PASS means something.
```

Planted cases, each checked against the same SQL:

```
0. empty table                                             -> verdict=FAIL
A. one masked pii-demo row, nothing leaked                 -> verdict=PASS
B. A + raw card number in input                            -> verdict=FAIL
C. masked input, raw RRN in output                         -> verdict=FAIL
D. masked payload, raw e-mail only in metadata             -> verdict=FAIL
E. raw API key in input, no placeholder anywhere           -> verdict=FAIL
F. pii-demo rows but no placeholder (masking did nothing)  -> verdict=FAIL
G. placeholder but no pii-demo rows                        -> verdict=FAIL
```

**Result.** The four raw secrets return **leak count 0** across input, output and metadata. **24 rows** carry `[REDACTED_*]`, and the sidecar logged 108 redactions.

**Scope.** Masking applies to the OTLP endpoint `/api/public/otel`, which is what SDK v3+ uses. `FAIL_CLOSED=true` drops an event if the callback errors.

## Lab 09 — Protected Prompt Labels

```console
$ ./09-ee-protected-prompts.sh
════ 1. Create v1 … labelled 'production' ════   → {version:1, labels:[production,latest]}
════ 2. Create v2 (stricter) and MOVE 'production' ════ → {version:2, labels:[production,latest]}
════ 3. Resolve current production prompt ════
  {version:2, prompt:"You are Acme's senior support assistant. Be concise, cite the KB article id, and never guess."}
════ 4. Prompts are OLTP → stored in POSTGRES, not ClickHouse ════
 version |       labels        |       created_at
---------+---------------------+-------------------------
       1 | {}                  | 2026-10-01 23:24:18.902
       2 | {production,latest} | 2026-10-01 23:24:18.948
════ 5. Every label change was AUDITED (ties to lab 07) ════
 create | prompt   (×2)
```

After v2 takes `production` + `latest`, **v1's labels become `{}`**. Deployment labels are unique pointers that move, not tags you accumulate. Prompts live in **Postgres**.

The EE capstone, a UI toggle, marks `production` as **protected** so that lab 06's roles apply. Bob (`VIEWER`) and Alice (`MEMBER`) can no longer repoint or delete it; only Owner / Admin can.

## Lab 10 — Instance Governance (UI Customization + Org Creators)

```console
$ ./10-ee-instance-governance.sh
▶ Redeploying langfuse-web with the governance overlay…
time="…" level=warning msg="Found orphan containers (langfuse-hols-masking-1) …"
▶ Proving the governance env is injected into the running container:
LANGFUSE_ALLOWED_ORGANIZATION_CREATORS=admin@example.com
LANGFUSE_UI_DOCUMENTATION_HREF=https://clickhouse.com/docs
LANGFUSE_UI_FEEDBACK_HREF=https://github.com/ClickHouse/clickhouse-hols/issues
LANGFUSE_UI_LOGO_DARK_MODE_HREF=https://clickhouse.com/favicon.ico
LANGFUSE_UI_LOGO_LIGHT_MODE_HREF=https://clickhouse.com/favicon.ico
LANGFUSE_UI_SUPPORT_HREF=https://clickhouse.com/support
✅ Governance config active.
```

Both controls are env-driven and license-gated. The script proves injection by `exec`-ing `env` inside the running container.

The **orphan-container warning is expected**. Lab 10's overlay set does not include lab 08's sidecar, so recreating `web` / `worker` drops the masking wiring. Overlays are independent; combine them to run several features at once.

## Lab 11 — Parquet Export ↔ ClickHouse

```console
$ ./11-ee-parquet-export.sh
════════════ A) Configure a scheduled Parquet export (Langfuse Org API) ════════════
▶ PUT /api/public/integrations/blob-storage → try Parquet first…
  ✅ Parquet scheduled export configured:
{
  "type": "S3_COMPATIBLE",
  "bucketName": "langfuse",
  "fileType": "PARQUET",
  "exportSource": "OBSERVATIONS_V2",
  "exportFrequency": "hourly",
  "exportMode": "FULL_HISTORY",
  "enabled": true
}

════════════ B) The ClickHouse primitive, live (INSERT INTO FUNCTION s3 → read back) ════════════
▶ ClickHouse version (Parquet export failures surface reliably on >= 25.11):
26.8.15.10
▶ Writing active observations (events_full) to Parquet on MinIO…
▶ Reading the Parquet back from MinIO (round-trip proof):
  rows in events_full (FINAL, active) = 182
  rows read back from the Parquet     = 182
  ✅ 182 == 182
▶ Schema ClickHouse inferred from the exported Parquet:
 1. │ project_id      │ String                         │
 2. │ trace_id        │ String                         │
 …
 5. │ start_time      │ DateTime64(6, 'UTC')           │
 …
15. │ tags            │ Array(String)                  │
```

**Part A.** On 4.48.0 the integration API **accepts `fileType: PARQUET`**, with the enriched `OBSERVATIONS_V2` export source. On v3.197.1 the same request returned HTTP 400 (`JSON` / `CSV` / `JSONL` only). The scheduled job runs hourly and had not fired before teardown, so this run proves the configuration, not the scheduled files.

**Part B.** This is the primitive the scheduled exporter uses: `INSERT INTO FUNCTION s3(...) … 'Parquet'`, then read it back. The ClickHouse-backed store can archive itself to object storage and stay queryable by ClickHouse, DuckDB, Athena or Spark. It pairs with lab 07 as **archive-then-delete**.

---

## Findings & gotchas (blog-worthy)

1. **v4 writes somewhere else.** Observations land in `events_full` / `events_core`; the v3 `traces` / `observations` tables still exist and get **0 rows**. Any v3-era query returns empty results instead of an error. That is why lab 03 prints the v3 row counts next to the v4 ones.

2. **A negative check needs a positive control.** "0 leaked secrets" on an empty table is not a result. The masking proof now ends in a verdict that requires PII rows and placeholders to exist, and it was shown to FAIL on an empty table and on six other planted cases (leaks, a missing placeholder, no PII rows). Masking stays provable in the warehouse: 0 leaks, 24 masked rows, 108 redactions.

3. **No joins for trace context.** v4 writes `trace_name`, `user_id`, `session_id`, `tags` and metadata onto every observation row. The roots are `is_app_root = true`. Cost by tier or user is now a single-table `GROUP BY`.

4. **Cost depends on the usage key names.** Langfuse prices usage keys that match the model's price definition. Measured on 4.48.0 with a throwaway stack:
   - `gpt-4o-mini` with `input` / `output` → priced
   - `gpt-4o-mini` with `input_tokens` / `output_tokens` → `total_cost = 0`
   - `claude-haiku-4-5` → priced with either
   - `claude-3-5-sonnet-20241022` (used before this run) → no price definition at all

   The generator now sends `input` / `output` and simulates only priced models.

5. **ReplacingMergeTree, reconsidered.** The v4 events table is "mostly immutable": raw rows equalled `FINAL` (137 = 137), where v3's `traces` had 41 raw rows for 40 traces. Keep reading with `FINAL` + `is_deleted = 0` anyway; retention deletes and updates still create versions.

6. **Pin, then re-check the drift on each pin.** On v3.197.1 the integration API rejected `PARQUET` with HTTP 400 although the public OpenAPI spec listed it. On 4.48.0 it is accepted, with the `OBSERVATIONS_V2` source. The finding that lasts is the habit: pin the image, and validate the API surface against the *running* version.

7. **Real model calls are just another OTel producer.** The official Anthropic SDK, instrumented by `opentelemetry-instrumentation-anthropic`, lands as `GENERATION` rows. They carry the dated model ID `claude-haiku-4-5-20251001`, which Langfuse's model definition matches, so they are priced. The whole run's Anthropic spend was about **$0.017** at list price.

8. **Deployment labels move.** Creating prompt v2 with `production` cleared the label from v1 (`labels = {}`). That is why protected labels exist.

9. **Overlays are independent; expect orphan warnings.** Bringing one overlay up recreates `web` / `worker` with that overlay's env only.

## Reproduce it

```bash
# from the repository root
python3.12 -m venv .venv && .venv/bin/pip install -r _base/requirements.txt   # Python 3.10+
labs/langfuse-ee/01-up.sh            # OSS stack; creates _base/.env from _base/.env.example
# set LANGFUSE_EE_LICENSE_KEY (and ADMIN_API_KEY) in _base/.env for 05–11;
# ANTHROPIC_API_KEY is optional (real model calls)
_base/bin/check.sh

cd labs/langfuse-ee
../../.venv/bin/python 02-generate-traces.py
docker exec -i langfuse-hols-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse --multiquery < 03-clickhouse-explore.sql
docker exec -i langfuse-hols-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse --multiquery < 04-clickhouse-analytics.sql

./05-ee-activate.sh                  # → EE
./06-ee-rbac-scim.sh
./07-ee-audit-retention.sh
./08-ee-data-masking.sh              # ⭐ masking verdict in ClickHouse (exits 1 on FAIL)
./09-ee-protected-prompts.sh
./10-ee-instance-governance.sh
./11-ee-parquet-export.sh            # Parquet ↔ ClickHouse round-trip

./99-cleanup.sh --purge              # tear down + wipe volumes
```

---

## 한국어 블로그 아웃라인 (Korean blog outline)

바로 글로 옮길 수 있도록 정리한 서술 구조입니다.

**제목(안):** "Langfuse v4를 ClickHouse 위에서 셀프호스팅하기 — 엔터프라이즈 기능까지 직접 돌려본 기록"

1. **왜 이 글인가**
   - 대부분의 Langfuse 튜토리얼은 "Cloud에 trace 보내기"에서 끝난다.
   - 이 글은 셀프호스팅과, 그 밑을 떠받치는 **ClickHouse 백엔드**를 SA 관점에서 직접 열어 본다.
   - 환경: Langfuse v4.48.0 / ClickHouse 26.8.15.10 / SDK 4.16.0.
2. **아키텍처 한 장**
   - 구성: web·worker, Postgres(OLTP: 사용자·조직·프롬프트·감사 로그), **ClickHouse(OLAP)**, Redis, MinIO.
   - v4에서는 observation이 `events_full`·`events_core`에 쌓인다.
3. **v4의 핵심 변화**
   - v3 테이블은 남아 있지만 0행이다. 그래서 v3 시절 SQL은 오류 없이 빈 결과만 낸다. (발견 #1)
   - trace 속성이 모든 행에 붙으므로 조인이 필요 없다. (발견 #3)
4. **OSS 트랙 (01–04)**
   - headless init로 클릭 없이 부팅하고, SDK로 trace 40건을 보낸다.
   - ClickHouse SQL로 비용·지연 p95·품질을 분석한다.
   - 함정: usage 키 이름(`input`/`output`)이 맞지 않으면 비용이 0이 된다. (발견 #4)
   - 원본 행 수와 FINAL 행 수가 같아진 이유. (발견 #5)
5. **Enterprise 트랙 (05–11)**
   - 라이선스를 활성화하면 Instance Management API가 200을 돌려준다.
   - RBAC/SCIM: 조직 전체에서는 VIEWER지만 특정 프로젝트에서만 ADMIN인 Bob.
   - 데이터 보존과 감사 로그.
6. **하이라이트: 서버측 마스킹을 ClickHouse로 *증명***
   - 결과: `events_full`에서 원문 누출 0건, `[REDACTED_*]` 24행, 마스킹 108회.
   - 핵심은 **판정(verdict)**이다. 빈 테이블과 일부러 만든 다른 6가지 경우(누출, 플레이스홀더 없음, PII 행 없음)에서는 FAIL이 나와야 PASS를 믿을 수 있다. (발견 #2)
7. **프롬프트 거버넌스** — `production` 라벨이 v1에서 v2로 **이동**하는 것을 보면, 왜 protected label이 필요한지 이어진다. (발견 #8)
8. **데이터 반출: Parquet와 ClickHouse 라운드트립**
   - `INSERT INTO FUNCTION s3(...)`로 쓰고 되읽어 **182 == 182**를 확인한다. archive-then-delete 패턴이다.
   - v3.197.1에서 400이던 `PARQUET`가 4.48.0에서는 받아들여진다. 교훈은 버전을 고정하고, 고정할 때마다 실행 중인 버전으로 다시 확인하는 것이다. (발견 #6)
9. **실제 모델 호출** — Anthropic SDK를 OTel로 계측하면 GENERATION 행이 남고 비용도 계산된다. 이번 실행 비용은 약 $0.017. (발견 #7)
10. **마무리** — 셀프호스팅 Langfuse는 사실상 실전 ClickHouse 애플리케이션이다. ClickHouse가 있으면 관측성과 컴플라이언스(마스킹·보존·반출)를 *데이터로* 증명할 수 있다.

**추천 코드/캡처:**
- v3 테이블 0행과 v4 테이블 행 수
- 마스킹 판정 표(0–G)
- usage 키별 비용 비교
- `PARQUET` 응답(v3 400 → v4 200)
- `s3()` 182 == 182

모두 위 로그에서 그대로 인용할 수 있습니다.

---

*Generated 2026-10-02 by running every script in this directory end to end on the pinned stack. The console blocks are trimmed excerpts of that run's logs.*
