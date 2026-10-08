# Langfuse-on-ClickHouse Enterprise Workshop — Full Run Log & Blog Source

A complete, captured end-to-end run of every lab in [`labs/v4/langfuse-ee/`](./README.md): the OSS track (01–04) and the full Enterprise track (05–11), on the shared stack in [`_base/`](../../../_base/README.md). This is the raw material for a tech blog: real commands, real output, and the findings that came out of running it.

> Language note: the run log below is in English (console output is language-neutral). A Korean blog outline (한국어 블로그 아웃라인) is at the end.

---

## TL;DR

- Self-hosted **Langfuse v4.53.0** stores every observation in two new **ClickHouse 26.8.19.9** tables, `events_full` and `events_core`; scores stay in `scores`. We stood the stack up, sent traces with Python SDK 4.17.0, and ran cost, latency and quality analytics straight on ClickHouse — with no joins, because v4 puts the trace attributes on every observation row.
- We then activated an **Enterprise license** and exercised the EE entitlements end to end. The highlight is **server-side data masking, *proven* in ClickHouse with SQL**, ending in a PASS/FAIL verdict that was itself shown to FAIL on an empty table. The other one is a **Parquet export ↔ ClickHouse `s3()` round-trip**.
- The optional real model calls go to **Anthropic `claude-haiku-4-5`**, traced by OpenTelemetry and priced by Langfuse.
- Main findings, from the 2026-10-08 run (comparisons with v3.197.1 come from the earlier v3 run, and a few items are marked as not re-run):
  - v4 writes somewhere else, so v3-era SQL returns nothing.
  - Cost depends on the usage key names.
  - The masking proof needs a positive control.
  - The Parquet drift seen on v3.197.1 is gone on 4.53.0.

## Environment

| Component | Version / detail |
|---|---|
| Host | macOS (Darwin 25.6) |
| Docker Engine / Compose | 29.8.2 / v5.5.1 |
| Langfuse (web + worker) | **v4.53.0** (`langfuse/langfuse:4.53.0`, `langfuse/langfuse-worker:4.53.0`), default `events_only` write mode |
| ClickHouse | **26.8.19.9** (LTS) |
| Postgres / Redis / MinIO | 17.11 / 7.2.16 / `cgr.dev/chainguard/minio@sha256:4cf4831a…` (index digest of `latest`, resolved 2026-10-06) |
| Masking sidecar | `python:3.12.15-slim` (stdlib only) |
| Python SDK | `langfuse` **4.17.0** on Python 3.12.14 (OpenTelemetry-native) |
| Real model calls (optional) | `anthropic` 1.11.0 + `opentelemetry-instrumentation-anthropic` 0.62.4, model `claude-haiku-4-5` |
| Run date | 2026-10-08 KST. Timestamps below are UTC, 2026-10-08 05:56–05:58 |

Pins and the reason for each are in [`STATUS.md`](../../../STATUS.md). The Postgres, Redis, MinIO and sidecar versions are the pins in `_base/docker-compose*.yml`; the run logs do not print them.

## Run summary

| Lab | Feature | Result |
|---|---|---|
| 01 | Stack up (6 containers) | ✅ healthy; `check.sh v4`: 11 PASS, 1 SKIP (masking sidecar, expected); `/api/public/health` → 200 (Langfuse 4.53.0); ClickHouse migrations 50/50 |
| 02 | Generate traces (SDK) | ✅ 40 traces offline, plus 5 with real `claude-haiku-4-5` calls |
| 03 | Explore the ClickHouse backend | ✅ data in `events_full` / `events_core` (158 rows each), `scores` 88; v3 `traces` / `observations` **0** |
| 04 | Analytics on ClickHouse | ✅ cost / latency p95 / errors / tier / quality / leaderboard / trend / sessions, with no joins |
| 05 | Activate Enterprise | ✅ Instance Management API → HTTP 200 |
| 06 | RBAC & SCIM | ✅ org + project + 2 SCIM users + project-level role override |
| 07 | Data retention + audit | ✅ 14-day retention; audit log lists the lab-06 organization create, API-key mints and 2 memberships |
| 08 | **Server-side data masking** | ✅ **verdict PASS**: 24 masked rows, 0 leaks, 108 redactions; the verdict FAILs on an empty table (`--selftest`). The other planted cases were not re-run on 2026-10-08 |
| 09 | Protected prompt labels | ✅ v1→v2 label move; prompts in Postgres; audited |
| 10 | Instance governance | ✅ UI + org-creator vars injected and verified |
| 11 | Parquet export ↔ ClickHouse | ✅ **`fileType: PARQUET` accepted** with the `OBSERVATIONS_V2` source; `s3()` round-trip **182 == 182** |

All 16 steps of this lab's part of the run (reset through lab 11, including the real-call 02, the sidecar log and the selftest) exited 0 in the run's summary log.

---

## Reset — clean slate

```console
$ _base/bin/down.sh v4 --purge
▶ Stopping the v4 stack and DELETING all its data volumes…
✅ Stack v4 down, volumes removed.
```

## Lab 01 — Deploy the stack (OSS)

```console
$ ./01-up.sh
▶ Starting Langfuse v4 stack in OSS mode (postgres · clickhouse · redis · minio · web · worker)…
 …
 Container langfuse-hols-v4-langfuse-web-1 Started
▶ Waiting for langfuse-web to become healthy (first boot runs DB + ClickHouse migrations, ~2-3 min)…
..✅ Langfuse is up after ~15s.

────────────────────────────────────────────────────────────
  Langfuse UI      http://localhost:3000   (track v4)
  Login            admin@example.com / workshop-admin-pw
  Project          LLM Observability
  API public key   pk-lf-workshop-public

  MinIO console    http://localhost:9091   (minio / miniosecret)
  ClickHouse HTTP  http://localhost:8123   (clickhouse / clickhouse)

  Next (from the repository root):
    _base/bin/check.sh v4                  # readiness: containers, migrations, keys
    python3.12 -m venv .venv-v4 && source .venv-v4/bin/activate     # Python 3.10+
    pip install -r _base/v4/requirements.txt
    python _base/v4/seed_traces.py         # or the lab's own seed script
────────────────────────────────────────────────────────────
```

```console
$ _base/bin/check.sh v4
stack: langfuse-hols-v4  (env file: _base/.env)

PASS  container langfuse-web running
PASS  container langfuse-worker running
PASS  container postgres running, healthy
PASS  container clickhouse running, healthy
PASS  container redis running, healthy
PASS  container minio running, healthy
PASS  web http://localhost:3000/api/public/health -> 200 (Langfuse 4.53.0)
PASS  web version 4.53.0 equals LANGFUSE_VERSION (v4 pin or override)
PASS  worker http://localhost:3030/api/health -> 200
PASS  ClickHouse migrations finished (applied 50, shipped 50, dirty 0)
PASS  SDK keys accepted (http://localhost:3000/api/public/projects -> 200)
SKIP  masking sidecar
     not running -- only lab 08 (docker-compose.masking.yml) starts it

1 check(s) skipped -- a skip is not a pass.
stack is ready.
```

The compose file uses **headless initialization** (`LANGFUSE_INIT_*`) to create the first org, project, user and API keys on boot, so data can flow before anyone opens the UI.

`check.sh` checks more than "the server answers". It compares the latest row of ClickHouse's `schema_migrations` with the highest migration number shipped in the web image, and it checks that the version the health endpoint reports equals the pin. v4.53.0 ships 50; v3.197.1 shipped 34.

## Lab 02 — Generate traces via the Python SDK

```console
$ ANTHROPIC_API_KEY= python 02-generate-traces.py
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

**The real path.** Real calls use the official `anthropic` SDK. `opentelemetry-instrumentation-anthropic` turns each call into a GENERATION span, and v4's default span filter keeps it because it carries `gen_ai.*` attributes. Measured after the run (lab 03 and lab 04 below), the instrumented calls were:
- 5 `GENERATION` rows, one per real call, named `anthropic.chat` in the latest trace
- model `claude-haiku-4-5-20251001` (the dated ID the API returns)
- priced by Langfuse at $0.001333 for the 5 calls (138 input and 239 output tokens)

The instrumentation scope name on those rows was not queried on 2026-10-08.

## Lab 03 — Explore the ClickHouse backend

```console
$ docker exec -i langfuse-hols-v4-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse \
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
events_full         158
events_core         158
traces (v3)           0
observations (v3)     0
scores               88
```

The latest traces are read from their root rows (`is_app_root`). Trace attributes sit on every observation row:

```
ca56366f…  support-request  user_004  sess_user_004_0  ['env:production','feature:onboarding','tier:free']
025ab3de…  support-request  user_008  sess_user_008_0  ['env:production','feature:troubleshooting','tier:pro']
…
SPAN        support-request    root=true
SPAN        retrieve-context   root=false
GENERATION  anthropic.chat     root=false  claude-haiku-4-5-20251001  {'input':27,'output':44,'total':71,'input_cached_tokens':0,'input_cache_creation':0}  {'input':0.000027,'output':0.00022,'input_cached_tokens':0,'input_cache_creation':0,'total':0.000247}
SPAN        answer-generation  root=false
```

The latest trace is one of the five real-call traces, so its generation is the instrumented `anthropic.chat` call with the dated model ID.

**Columns.**
- `events_core` has the same columns as `events_full`, with truncated `input` / `output`. The materialized view `events_core_mv` fills it.
- `total_cost` is an `ALIAS` of `cost_details['total']`, and `calculated_*_cost` are `MATERIALIZED` from `cost_details`.
- Metadata is two parallel arrays, `metadata_names` / `metadata_values`.

**ReplacingMergeTree.** Raw rows and `FINAL` agreed in this run: **158 = 158**. On v3.197.1 the `traces` table showed 41 raw rows for 40 traces. Langfuse describes the v4 events table as "mostly immutable", which fits. The lab still reads with `FINAL` + `is_deleted = 0`, because retention deletes and updates do create row versions.

## Lab 04 — Analytics directly on ClickHouse

```console
$ docker exec -i langfuse-hols-v4-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse \
    --multiquery < 04-clickhouse-analytics.sql
```

Every query reads `events_core FINAL`. v3 needed a traces↔observations join to put a user or a tier next to a generation. v4 does not: the attributes are already on the row.

**1) Spend & tokens by model** — `sum()` over the `usage_details` map and `total_cost`:

| model | calls | input_tok | output_tok | total_cost_usd | avg_cost/call |
|---|--:|--:|--:|--:|--:|
| gpt-4o | 9 | 5,785 | 2,547 | 0.039932 | 0.004437 |
| claude-haiku-4-5 | 15 | 12,360 | 3,330 | 0.02901 | 0.001934 |
| gpt-4o-mini | 34 | 15,523 | 3,687 | 0.004541 | 0.000134 |
| claude-haiku-4-5-20251001 | 5 | 138 | 239 | 0.001333 | 0.000267 |

The last row is the five real calls of lab 02; the `claude-haiku-4-5` row is the simulated traffic.

**2) Latency p50/p95/p99 per model** — `quantile()` over `dateDiff('millisecond', start_time, end_time)`:

| model | calls | avg_ms | p50 | p95 | p99 |
|---|--:|--:|--:|--:|--:|
| claude-haiku-4-5-20251001 | 5 | 1,224 | 1,045 | 1,883.60 | 2,015.92 |
| gpt-4o | 9 | 792 | 724 | 1,337.00 | 1,407.40 |
| claude-haiku-4-5 | 15 | 532 | 545 | 804.60 | 816.92 |
| gpt-4o-mini | 34 | 226 | 182 | 524.85 | 553.04 |

**3) Error rate per model** — `countIf(level = 'ERROR')`:

| model | calls | errors | error_pct |
|---|--:|--:|--:|
| gpt-4o | 9 | 1 | 11.11 |
| claude-haiku-4-5 | 15 | 1 | 6.67 |
| claude-haiku-4-5-20251001 | 5 | 0 | 0 |
| gpt-4o-mini | 34 | 0 | 0 |

**4) Cost by customer tier** — the tier comes from the row's own tags, with no join:

| tier | traces | cost_usd | cost_per_trace |
|---|--:|--:|--:|
| free | 17 | 0.03053 | 0.001796 |
| pro | 14 | 0.028651 | 0.002046 |
| enterprise | 14 | 0.015635 | 0.001117 |

**5) Satisfaction from scores.**
- Thumbs-up by tier: enterprise 78.6%, free 76.5%, pro 85.7%.
- Overall: thumbs votes **45**, thumbs-up **80%**, average grounding **0.806**.

**6) Per-user spend leaderboard** (top rows):

| user | sessions | requests | cost |
|---|--:|--:|--:|
| `user_005` | 4 | 6 | $0.0138 |
| `user_011` | 4 | 4 | $0.0124 |
| `user_012` | 3 | 3 | $0.0106 |

**7) Daily trend:** `2026-10-08` (UTC) → 45 traces, 12 unique users, $0.074816.

**8) Session depth:** 31 sessions with 1 turn, 7 sessions with 2 turns.

---

## Lab 05 — Activate Enterprise

```console
$ ./05-ee-activate.sh
▶ Re-deploying with the Enterprise overlay (license key + admin API)…
▶ Waiting for langfuse-web to come back…
. ready.
▶ Verifying Enterprise activation via the Instance Management API…
✅ Enterprise active. Admin API reachable. Current organizations:
{"organizations":[{"id":"ch-workshop","name":"ClickHouse Workshop","createdAt":"2026-10-08T05:56:31.786Z","metadata":{},"projects":[{"id":"llm-observability","name":"LLM Observability", …}]}]}
```

The overlay injects `LANGFUSE_EE_LICENSE_KEY` into **both** containers, plus `ADMIN_API_KEY`. `/api/admin/organizations` only answers HTTP 200 when a valid license is present. CI checks that both containers get the key in every overlay set.

## Lab 06 — RBAC & SCIM (full self-service admin chain)

```console
$ ./06-ee-rbac-scim.sh
════ 1. Create an organization (Instance Management API, Bearer auth) ════
  org id = cmuz4kaaf0002ny078bqlqzi8
════ 2. Mint an organization-scoped API key ════
  org public key = pk-lf-e0f656db-…
════ 3. Create a project under the org ════
  project id = cmuz4kagd0008ny07ef4118is
════ 4. Mint a project API key (this is what an app would use to send traces) ════
  project public key = pk-lf-95101723-…
════ 5. SCIM: provision two users (as an IdP like Okta/Entra would) ════
  alice id = cmuz4kalq…   bob id = cmuz4kamk…
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
▶ Minting an org-scoped key for 'ch-workshop' to call the projects API…
▶ Setting 14-day retention on project 'llm-observability'…
{ "id": "llm-observability", "name": "LLM Observability", "retentionDays": 14 }

════════════════ B) Audit Logs ════════════════
▶ Audit logs are stored in Postgres. Discovering the table…
  table = audit_logs
▶ Schema:
 …
▶ Most recent audit events (who did what, when) — including the org/project/
  membership changes lab 06 just made (columns are snake_case in Postgres):
       created_at        | action | resource_type |  actor
-------------------------+--------+---------------+-----------
 2026-10-08 05:57:42.017 | create | apiKey        | ADMIN_KEY
 2026-10-08 05:57:41.711 | create | orgMembership | cmuz4kaes…
 2026-10-08 05:57:41.682 | create | orgMembership | cmuz4kaes…
 2026-10-08 05:57:41.634 | create | apiKey        | ORG_KEY
 2026-10-08 05:57:41.431 | create | apiKey        | ADMIN_KEY
 2026-10-08 05:57:41.276 | create | organization  | ADMIN_KEY
```

A non-zero retention value requires the data-retention entitlement. A nightly worker then deletes event data older than the window. The audit log is the immutable who / what / when. The six most recent events are the lab-06 organization create, its API-key mints and the two memberships, plus the org-scoped key that lab 07 itself minted (the top row, 05:57:42.017). The six rows do not include the project create, the SCIM users or the project-level role override, so this run does not show that every lab-06 action is audited.

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
  (using interpreter: .venv-v4/bin/python)
✓ Connected. Sending 12 PII-laden traces to the OTLP endpoint…
▶ Letting the worker ingest + mask (async)…
▶ Verifying against ClickHouse (events_full) — raw secrets should be GONE, [REDACTED_*] present:
pii-demo rows present	24
── events_full: raw-secret leak counts (want all 0) ──
0	0	0	0
── pii-demo rows carrying a [REDACTED_*] placeholder (want > 0) ──
24	24
── sample masked observation payloads ──
name:            answer-generation
input_sample:    [{"role": "system", "content": "You are a support assistant. Never echo secrets."}, {"role": "user", "content": "Reset my login for [REDACTED_EMAIL]."}]
output_sample:   A reset link was sent to [REDACTED_EMAIL].
meta_raw_email:  [REDACTED_EMAIL]
meta_raw_rrn:    [REDACTED_KR_RRN]
…
verdict	PASS	24	24	0
✅ MASKING VERDICT: PASS.
```

```console
$ docker logs --tail 60 langfuse-hols-v4-masking-1
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

Planted cases, each checked against the same SQL. Case 0 was re-run on 2026-10-08 (the selftest above). Cases A–G were last run on 2026-10-02 (Langfuse 4.48.0) and were not re-run since, so their verdicts below are the earlier results:

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
       1 | {}                  | 2026-10-08 05:58:00.533
       2 | {production,latest} | 2026-10-08 05:58:00.575
════ 5. Every label change was AUDITED (ties to lab 07) ════
 create | prompt   (×2)
```

After v2 takes `production` + `latest`, **v1's labels become `{}`**. Deployment labels are unique pointers that move, not tags you accumulate. Prompts live in **Postgres**.

The EE capstone, a UI toggle, marks `production` as **protected** so that lab 06's roles apply. Bob (`VIEWER`) and Alice (`MEMBER`) can no longer repoint or delete it; only Owner / Admin can.

## Lab 10 — Instance Governance (UI Customization + Org Creators)

```console
$ ./10-ee-instance-governance.sh
▶ Redeploying langfuse-web with the governance overlay…
time="…" level=warning msg="Found orphan containers (langfuse-hols-v4-masking-1) …"
▶ Proving the governance env is injected into the running container:
LANGFUSE_ALLOWED_ORGANIZATION_CREATORS=admin@example.com
LANGFUSE_UI_DOCUMENTATION_HREF=https://clickhouse.com/docs
LANGFUSE_UI_FEEDBACK_HREF=https://github.com/ClickHouse/clickhouse-hols/issues
LANGFUSE_UI_LOGO_DARK_MODE_HREF=https://clickhouse.com/favicon.ico
LANGFUSE_UI_LOGO_LIGHT_MODE_HREF=https://clickhouse.com/favicon.ico
LANGFUSE_UI_SUPPORT_HREF=https://clickhouse.com/support
✅ Governance config active. …
```

Both controls are env-driven and license-gated. The script proves injection by `exec`-ing `env` inside the running container.

The **orphan-container warning is expected**. Lab 10's overlay set does not include lab 08's sidecar, so recreating `web` / `worker` drops the masking wiring. Overlays are independent; combine them to run several features at once.

## Lab 11 — Parquet Export ↔ ClickHouse

```console
$ ./11-ee-parquet-export.sh
════════════ A) Configure a scheduled Parquet export (Langfuse Org API) ════════════
▶ Minting an org-scoped key for 'ch-workshop'…
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
26.8.19.9
▶ Writing active observations (events_full) to Parquet on MinIO…
▶ Reading the Parquet back from MinIO (round-trip proof):
  rows in events_full (FINAL, active) = 182
  rows read back from the Parquet     = 182
  ✅ 182 == 182
▶ Schema ClickHouse inferred from the exported Parquet (first 15 columns):
 1. │ project_id      │ String                         │
 2. │ trace_id        │ String                         │
 …
 5. │ start_time      │ DateTime64(6, 'UTC')           │
 …
15. │ tags            │ Array(String)                  │
```

**Part A.** On 4.53.0 the integration API **accepts `fileType: PARQUET`**, with the enriched `OBSERVATIONS_V2` export source. On v3.197.1 the same request returned HTTP 400 (`JSON` / `CSV` / `JSONL` only). The scheduled job runs hourly. This run did not look for the scheduled files, and the next step purged the stack, so it proves the configuration, not the scheduled files.

**Part B.** This is the primitive the scheduled exporter uses: `INSERT INTO FUNCTION s3(...) … 'Parquet'`, then read it back. The ClickHouse-backed store can archive itself to object storage and stay queryable by ClickHouse, DuckDB, Athena or Spark. It pairs with lab 07 as **archive-then-delete**.

182 equals the 158 rows of lab 03 plus the 24 `pii-demo` rows of lab 08.

---

## Findings & gotchas (blog-worthy)

1. **v4 writes somewhere else.** Observations land in `events_full` / `events_core`; the v3 `traces` / `observations` tables still exist and get **0 rows**. Any v3-era query returns empty results instead of an error. That is why lab 03 prints the v3 row counts next to the v4 ones.

2. **A negative check needs a positive control.** "0 leaked secrets" on an empty table is not a result. The masking proof now ends in a verdict that requires PII rows and placeholders to exist. It was shown to FAIL on an empty table on 2026-10-08. On 2026-10-02 it was also shown to FAIL on six other planted cases (leaks, a missing placeholder, no PII rows); those were not re-run since. Masking stays provable in the warehouse: 0 leaks, 24 masked rows, 108 redactions.

3. **No joins for trace context.** v4 writes `trace_name`, `user_id`, `session_id`, `tags` and metadata onto every observation row. The roots are `is_app_root = true`. Cost by tier or user is now a single-table `GROUP BY`.

4. **Cost depends on the usage key names.** Langfuse prices usage keys that match the model's price definition. Measured on 4.48.0 with a throwaway stack on 2026-10-02 (not re-run since):
   - `gpt-4o-mini` with `input` / `output` → priced
   - `gpt-4o-mini` with `input_tokens` / `output_tokens` → `total_cost = 0`
   - `claude-haiku-4-5` → priced with either
   - `claude-3-5-sonnet-20241022` (used before that run) → no price definition at all

   The generator now sends `input` / `output` and simulates only priced models. On 2026-10-08 every model in the lab-04 cost table came out priced.

5. **ReplacingMergeTree, reconsidered.** The v4 events table is "mostly immutable": raw rows equalled `FINAL` (158 = 158), where v3's `traces` had 41 raw rows for 40 traces. Keep reading with `FINAL` + `is_deleted = 0` anyway; retention deletes and updates still create versions.

6. **Pin, then re-check the drift on each pin.** On v3.197.1 the integration API rejected `PARQUET` with HTTP 400 although the public OpenAPI spec listed it. On 4.53.0 it is accepted, with the `OBSERVATIONS_V2` source. The finding that lasts is the habit: pin the image, and validate the API surface against the *running* version.

7. **Real model calls are just another OTel producer.** The official Anthropic SDK, instrumented by `opentelemetry-instrumentation-anthropic`, lands as `GENERATION` rows. They carry the dated model ID `claude-haiku-4-5-20251001`, which Langfuse's model definition matches, so they are priced. Lab 02's 5 real calls were priced by Langfuse at **$0.001333**. The eval lab's real calls ran in the same session; their cost was not summed here.

8. **Deployment labels move.** Creating prompt v2 with `production` cleared the label from v1 (`labels = {}`). That is why protected labels exist.

9. **Overlays are independent; expect orphan warnings.** Bringing one overlay up recreates `web` / `worker` with that overlay's env only.

## Reproduce it

```bash
# from the repository root
python3.12 -m venv .venv-v4 && .venv-v4/bin/pip install -r _base/v4/requirements.txt   # Python 3.10+
labs/v4/langfuse-ee/01-up.sh         # = _base/bin/up.sh v4; OSS stack, creates _base/.env from _base/.env.example
# set LANGFUSE_EE_LICENSE_KEY (and ADMIN_API_KEY) in _base/.env for 05–11;
# ANTHROPIC_API_KEY is optional (real model calls)
_base/bin/check.sh v4

cd labs/v4/langfuse-ee
../../../.venv-v4/bin/python 02-generate-traces.py
docker exec -i langfuse-hols-v4-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse --multiquery < 03-clickhouse-explore.sql
docker exec -i langfuse-hols-v4-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse --multiquery < 04-clickhouse-analytics.sql

./05-ee-activate.sh                  # → EE
./06-ee-rbac-scim.sh
./07-ee-audit-retention.sh
./08-ee-data-masking.sh              # ⭐ masking verdict in ClickHouse (exits 1 on FAIL)
./09-ee-protected-prompts.sh
./10-ee-instance-governance.sh
./11-ee-parquet-export.sh            # Parquet ↔ ClickHouse round-trip

./99-cleanup.sh --purge              # = _base/bin/down.sh v4 --purge; tear down + wipe volumes
```

---

## 한국어 블로그 아웃라인 (Korean blog outline)

바로 글로 옮길 수 있도록 정리한 서술 구조입니다.

**제목(안):** "Langfuse v4를 ClickHouse 위에서 셀프호스팅하기 — 엔터프라이즈 기능까지 직접 돌려본 기록"

1. **왜 이 글인가**
   - 대부분의 Langfuse 튜토리얼은 "Cloud에 trace 보내기"에서 끝난다.
   - 이 글은 셀프호스팅과, 그 밑을 떠받치는 **ClickHouse 백엔드**를 SA 관점에서 직접 열어 본다.
   - 환경: Langfuse v4.53.0 / ClickHouse 26.8.19.9 / SDK 4.17.0.
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
   - 핵심은 **판정(verdict)**이다. 빈 테이블에서는 FAIL이 나오는 것을 2026-10-08에 다시 확인했다. 그 밖의 계획된 6가지 경우(누출, 플레이스홀더 없음, PII 행 없음)는 2026-10-02 실행에서 확인했고 이번에는 다시 돌리지 않았다. FAIL이 나와야 PASS를 믿을 수 있다. (발견 #2)
7. **프롬프트 거버넌스** — `production` 라벨이 v1에서 v2로 **이동**하는 것을 보면, 왜 protected label이 필요한지 이어진다. (발견 #8)
8. **데이터 반출: Parquet와 ClickHouse 라운드트립**
   - `INSERT INTO FUNCTION s3(...)`로 쓰고 되읽어 **182 == 182**를 확인한다. archive-then-delete 패턴이다.
   - v3.197.1에서 400이던 `PARQUET`가 4.53.0에서는 받아들여진다. 교훈은 버전을 고정하고, 고정할 때마다 실행 중인 버전으로 다시 확인하는 것이다. (발견 #6)
9. **실제 모델 호출** — Anthropic SDK를 OTel로 계측하면 GENERATION 행이 남고 비용도 계산된다. 랩 02의 실제 호출 5건은 Langfuse 가격 기준 $0.001333이었다(eval 랩의 실제 호출 비용은 합산하지 않았다). (발견 #7)
10. **마무리** — 셀프호스팅 Langfuse는 사실상 실전 ClickHouse 애플리케이션이다. ClickHouse가 있으면 관측성과 컴플라이언스(마스킹·보존·반출)를 *데이터로* 증명할 수 있다.

**추천 코드/캡처:**
- v3 테이블 0행과 v4 테이블 행 수
- 마스킹 판정 표(0–G; 0만 2026-10-08에 재실행)
- usage 키별 비용 비교(2026-10-02 측정)
- `PARQUET` 응답(v3 400 → v4 200)
- `s3()` 182 == 182

위 로그에서 그대로 인용할 수 있습니다. 단, 2026-10-02 측정으로 표시한 항목은 이번 실행에서 다시 돌리지 않았습니다.

---

*Generated 2026-10-08 by running every script in this directory end to end on the pinned stack (Langfuse v4.53.0 / SDK 4.17.0 / ClickHouse 26.8.19.9). The console blocks are trimmed excerpts of that run's logs.*
