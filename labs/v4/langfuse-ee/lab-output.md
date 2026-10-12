# Langfuse-on-ClickHouse Enterprise Workshop — Full Run Log & Blog Source

A complete, captured end-to-end run of every lab in [`labs/v4/langfuse-ee/`](./README.md): the OSS track (01–04) and the full Enterprise track (05–11), on the shared stack in [`_base/`](../../../_base/README.md). This is the raw material for a tech blog: real commands, real output, and the findings that came out of running it.

> Language note: the run log below is in English (console output is language-neutral). A Korean blog outline (한국어 블로그 아웃라인) is at the end.

---

## TL;DR

- Self-hosted **Langfuse v4.56.0** stores every observation in two new **ClickHouse 26.8.22.13** tables, `events_full` and `events_core`; scores stay in `scores`. We stood the stack up, sent traces with Python SDK 4.17.0, and ran cost, latency and quality analytics straight on ClickHouse — with no joins, because v4 puts the trace attributes on every observation row.
- We then activated an **Enterprise license** and exercised the EE entitlements end to end. The highlight is **server-side data masking, *proven* in ClickHouse with SQL**, ending in a PASS/FAIL verdict that was itself shown to FAIL on an empty table. The other one is a **Parquet export ↔ ClickHouse `s3()` round-trip**.
- The optional real model calls go to **Anthropic `claude-haiku-4-5`**, traced by OpenTelemetry and priced by Langfuse.
- Main findings, from the 2026-10-10 run (comparisons with v3.197.1 come from the earlier v3 run, and a few items are marked as not re-run):
  - v4 writes somewhere else, so v3-era SQL returns nothing.
  - Cost depends on the usage key names.
  - The masking proof needs a positive control.
  - The Parquet drift seen on v3.197.1 is gone on 4.56.0.

## Environment

| Component | Version / detail |
|---|---|
| Host | macOS (Darwin 25.6) |
| Docker Engine / Compose | 29.8.2 / v5.5.1 |
| Langfuse (web + worker) | **v4.56.0** (`langfuse/langfuse:4.56.0`, `langfuse/langfuse-worker:4.56.0`), default `events_only` write mode |
| ClickHouse | **26.8.22.13** (LTS) |
| Postgres / Redis / MinIO | 17.11 / 7.2.16 / `cgr.dev/chainguard/minio@sha256:4cf4831a…` (index digest of `latest`, resolved 2026-10-06) |
| Masking sidecar | `python:3.12.15-slim` (stdlib only) |
| Python SDK | `langfuse` **4.17.0** on Python 3.12.14 (OpenTelemetry-native) |
| Real model calls (optional) | `anthropic` 1.12.1 + `opentelemetry-instrumentation-anthropic` 0.62.4, model `claude-haiku-4-5` |
| Run date | 2026-10-10 KST. Timestamps below are UTC, 2026-10-09 15:21–15:25 |

Pins and the reason for each are in [`STATUS.md`](../../../STATUS.md). The Postgres, Redis, MinIO and sidecar versions are the pins in `_base/docker-compose*.yml`; the run logs do not print them.

## Run summary

| Lab | Feature | Result |
|---|---|---|
| 01 | Stack up (6 containers) | ✅ healthy; `check.sh v4`: 11 PASS, 1 SKIP (masking sidecar, expected); `/api/public/health` → 200 (Langfuse 4.56.0); ClickHouse migrations 51/51 |
| 02 | Generate traces (SDK) | ✅ 40 traces offline, plus 5 with real `claude-haiku-4-5` calls |
| 03 | Explore the ClickHouse backend | ✅ data in `events_full` / `events_core` (158 rows each), `scores` 88; v3 `traces` / `observations` **0** |
| 04 | Analytics on ClickHouse | ✅ cost / latency p95 / errors / tier / quality / leaderboard / trend / sessions, with no joins |
| 05 | Activate Enterprise | ✅ Instance Management API → HTTP 200 |
| 06 | RBAC & SCIM | ✅ org + project + 2 SCIM users + project-level role override |
| 07 | Data retention + audit | ✅ 14-day retention; audit log (9 rows) lists the lab-06 organization create, API-key mints, 2 memberships, their 2 role updates and the project-level role override |
| 08 | **Server-side data masking** | ✅ **verdict PASS**: 24 masked rows, 0 leaks, 108 redactions; the verdict FAILs on an empty table (`--selftest`). The other planted cases were not re-run on 2026-10-10 |
| 09 | Protected prompt labels | ✅ v1→v2 label move; prompts in Postgres; audited |
| 10 | Instance governance | ✅ UI + org-creator vars injected and verified |
| 11 | Parquet export ↔ ClickHouse | ✅ **`fileType: PARQUET` accepted** with the `OBSERVATIONS_V2` source; `s3()` round-trip **182 == 182** |
| 12 | Masking failure modes (2026-10-12) | ✅ 9 scenarios as the worker source says: fail-open stores raw on down / timeout / HTTP 500, fail-closed drops (log line + S3 object kept); per-project rule via `X-Langfuse-Project-Id`; legacy ingestion accepts only `score-create` and skips masking; the raw OTLP payload stays in S3 |
| 13 | Project isolation (2026-10-12) | ✅ 36 PASS: org `NONE` + project-A `VIEWER` sees A only (session list, tRPC 401 on B, browser "Project Not Found"); org `ADMIN` sees both |
| 14 | Field encryption in `mask_otel_spans` (2026-10-12) | ✅ 36 PASS: only `enc:v1:` ciphertext in `events_full` / `events_core` and the API; reader decrypts with the project key, wrong key → `InvalidTag`; input search finds 0 encrypted traces |
| 14b | Real LLM-as-a-judge on encrypted input (2026-10-13) | ✅ `claude-haiku-4-5` judged the stored ciphertext (`Question: enc:v1:…`) and scored both encrypted traces 0 ("encrypted ciphertext … not readable"); the plaintext control scored 1. 9 judge calls in 3 runs; the control scored 0 once with the first prompt wording |
| 15 | ClickHouse row policy (2026-10-12) | ✅ 30 PASS: `analyst_a` sees project A only on 12 tables; Langfuse's account unaffected (`users_without_row_policies_can_read_rows=true`); `CREATE MASKING POLICY` → Code 344 `SUPPORT_IS_DISABLED` |

All 17 steps of this lab's part of the run (reset through lab 11, including the real-call 02, the 10 s wait, the sidecar log and the selftest) exited 0 in the run's summary log.

---

## Reset — clean slate

```console
$ _base/bin/down.sh v3 --purge; _base/bin/down.sh v4 --purge
▶ Stopping the v3 stack and DELETING all its data volumes…
✅ Stack v3 down, volumes removed.
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
PASS  web http://localhost:3000/api/public/health -> 200 (Langfuse 4.56.0)
PASS  web version 4.56.0 equals LANGFUSE_VERSION (v4 pin or override)
PASS  worker http://localhost:3030/api/health -> 200
PASS  ClickHouse migrations finished (applied 51, shipped 51, dirty 0)
PASS  SDK keys accepted (http://localhost:3000/api/public/projects -> 200)
SKIP  masking sidecar
     not running -- only lab 08 (docker-compose.masking.yml) starts it

1 check(s) skipped -- a skip is not a pass.
stack is ready.
```

The compose file uses **headless initialization** (`LANGFUSE_INIT_*`) to create the first org, project, user and API keys on boot, so data can flow before anyone opens the UI.

`check.sh` checks more than "the server answers". It compares the latest row of ClickHouse's `schema_migrations` with the highest migration number shipped in the web image, and it checks that the version the health endpoint reports equals the pin. v4.56.0 ships 51; v3.197.1 shipped 34.

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
$ sleep 10
```

**The trace tree.** Each trace is a nested observation tree: a `support-request` root span, then a `retrieve-context` span, then an `answer-generation` generation, and occasionally a `self-check`. Every trace carries scores.

**SDK v4 changes.**
- SDK v4 has no `update_current_trace()`. The generator wraps the work in `propagate_attributes(trace_name=…, user_id=…, session_id=…, tags=…, metadata=…)`, which writes those attributes onto every observation it creates.
- Usage is sent as `{"input": …, "output": …}`, the keys Langfuse prices by.

**The real path.** Real calls use the official `anthropic` SDK. `opentelemetry-instrumentation-anthropic` turns each call into a GENERATION span, and v4's default span filter keeps it because it carries `gen_ai.*` attributes. Measured after the run (lab 03 and lab 04 below), the instrumented calls were:
- 5 `GENERATION` rows, one per real call, named `anthropic.chat` in the latest trace
- model `claude-haiku-4-5-20251001` (the dated ID the API returns)
- priced by Langfuse at $0.001303 for the 5 calls (138 input and 233 output tokens)

The instrumentation scope name on those rows was not queried on 2026-10-10.

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
topic_assignments             ReplacingMergeTree
topic_facet_summaries         ReplacingMergeTree
topics                        ReplacingMergeTree
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
87baa837…  support-request  user_004  sess_user_004_0  ['env:production','feature:onboarding','tier:free']
6ee173d0…  support-request  user_008  sess_user_008_0  ['env:production','feature:troubleshooting','tier:pro']
…
SPAN        support-request    root=true
SPAN        retrieve-context   root=false
SPAN        answer-generation  root=false
GENERATION  anthropic.chat     root=false  claude-haiku-4-5-20251001  {'input':27,'output':48,'total':75,'input_cached_tokens':0,'input_cache_creation':0}  {'input':0.000027,'output':0.00024,'input_cached_tokens':0,'input_cache_creation':0,'total':0.000267}
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
| claude-haiku-4-5-20251001 | 5 | 138 | 233 | 0.001303 | 0.000261 |

The last row is the five real calls of lab 02; the `claude-haiku-4-5` row is the simulated traffic.

**2) Latency p50/p95/p99 per model** — `quantile()` over `dateDiff('millisecond', start_time, end_time)`:

| model | calls | avg_ms | p50 | p95 | p99 |
|---|--:|--:|--:|--:|--:|
| gpt-4o | 9 | 792 | 723 | 1,337.40 | 1,407.48 |
| claude-haiku-4-5-20251001 | 5 | 1,058 | 1,069 | 1,243.20 | 1,275.84 |
| claude-haiku-4-5 | 15 | 532 | 545 | 806.30 | 818.06 |
| gpt-4o-mini | 34 | 226 | 183 | 525.80 | 552.71 |

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
| free | 17 | 0.030515 | 0.001795 |
| pro | 14 | 0.028626 | 0.002045 |
| enterprise | 14 | 0.015645 | 0.001117 |

**5) Satisfaction from scores.**
- Thumbs-up by tier: enterprise 78.6%, free 76.5%, pro 85.7%.
- Overall: thumbs votes **45**, thumbs-up **80%**, average grounding **0.806**.

**6) Per-user spend leaderboard** (top rows):

| user | sessions | requests | cost |
|---|--:|--:|--:|
| `user_005` | 4 | 6 | $0.0138 |
| `user_011` | 4 | 4 | $0.0124 |
| `user_012` | 3 | 3 | $0.0106 |

**7) Daily trend:** `2026-10-09` (UTC) → 45 traces, 12 unique users, $0.074786.

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
{"organizations":[{"id":"ch-workshop","name":"ClickHouse Workshop","createdAt":"2026-10-09T15:23:58.901Z","metadata":{},"projects":[{"id":"llm-observability","name":"LLM Observability", …}]}]}
```

The overlay injects `LANGFUSE_EE_LICENSE_KEY` into **both** containers, plus `ADMIN_API_KEY`. `/api/admin/organizations` only answers HTTP 200 when a valid license is present. CI checks that both containers get the key in every overlay set.

## Lab 06 — RBAC & SCIM (full self-service admin chain)

```console
$ ./06-ee-rbac-scim.sh
════ 1. Create an organization (Instance Management API, Bearer auth) ════
  org id = cmv149scj0002o13ro5tst9k3
════ 2. Mint an organization-scoped API key ════
  org public key = pk-lf-3a28ffa1-…
════ 3. Create a project under the org ════
  project id = cmv149si3000ao13r47rbfnr5
════ 4. Mint a project API key (this is what an app would use to send traces) ════
  project public key = pk-lf-acfb0ae3-…
════ 5. SCIM: provision two users (as an IdP like Okta/Entra would) ════
  alice id = cmv149snf…   bob id = cmv149so7…
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
       created_at        | action |   resource_type   |  actor
-------------------------+--------+-------------------+-----------
 2026-10-09 15:25:04.6   | create | apiKey            | ADMIN_KEY
 2026-10-09 15:25:04.314 | create | projectMembership | cmv149sgv…
 2026-10-09 15:25:04.288 | update | orgMembership     | cmv149sgv…
 2026-10-09 15:25:04.263 | update | orgMembership     | cmv149sgv…
 2026-10-09 15:25:04.236 | create | orgMembership     | cmv149sgv…
 2026-10-09 15:25:04.206 | create | orgMembership     | cmv149sgv…
 2026-10-09 15:25:04.163 | create | apiKey            | cmv149sgv…
 2026-10-09 15:25:03.971 | create | apiKey            | ADMIN_KEY
 2026-10-09 15:25:03.816 | create | organization      | ADMIN_KEY
```

A non-zero retention value requires the data-retention entitlement. A nightly worker then deletes event data older than the window. The audit log is the immutable who / what / when. The nine most recent events are the lab-06 organization create, its two API-key mints, the two memberships with their two role updates and the project-level role override (`create projectMembership`), plus the org-scoped key that lab 07 itself minted (the top row, 15:25:04.6, in org `ch-workshop`). The nine rows do not include the project create or the SCIM users, so this run does not show that every lab-06 action is audited.

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
  (using interpreter: ../../../.venv-v4/bin/python)
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
input_sample:    [{"role": "system", "content": "You are a support assistant. Never echo secrets."}, {"role": "user", "content": "My card [REDACTED_CC] was charged twice, please refund."}]
output_sample:   I've opened a refund for the card ending in the number you sent ([REDACTED_CC]).
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

Planted cases, each checked against the same SQL. Case 0 was re-run on 2026-10-10 (the selftest above). Cases A–G were last run on 2026-10-02 (Langfuse 4.48.0) and were not re-run since, so their verdicts below are the earlier results:

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
       1 | {}                  | 2026-10-09 15:25:23.277
       2 | {production,latest} | 2026-10-09 15:25:23.314
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
26.8.22.13
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

**Part A.** On 4.56.0 the integration API **accepts `fileType: PARQUET`**, with the enriched `OBSERVATIONS_V2` export source. On v3.197.1 the same request returned HTTP 400 (`JSON` / `CSV` / `JSONL` only). The scheduled job runs hourly. This run did not look for the scheduled files, and the next step purged the stack, so it proves the configuration, not the scheduled files.

**Part B.** This is the primitive the scheduled exporter uses: `INSERT INTO FUNCTION s3(...) … 'Parquet'`, then read it back. The ClickHouse-backed store can archive itself to object storage and stay queryable by ClickHouse, DuckDB, Athena or Spark. It pairs with lab 07 as **archive-then-delete**.

182 equals the 158 rows of lab 03 plus the 24 `pii-demo` rows of lab 08.

---

## Lab 12 — Ingestion masking failure modes (2026-10-12)

Langfuse v4.56.0 / SDK 4.17.0 / CH 26.8.22.13, EE overlay up, `events_only` write mode. Command: `labs/v4/langfuse-ee/12-ee-masking-failure-modes.sh` (exit 0).

```text
════ 0. Setup: org, projects A and B, API keys ════
  org cmv5atyvw00ntmw4168ph818g  project A cmv5atz1v00o1mw4105dqia47  project B cmv5atz6w00o8mw41e38g17o1
  account number used in every payload: 110-23-812387 (fabricated)
  worker image: docker.io/langfuse/langfuse-worker:4.56.0   sidecar image: docker.io/python:3.12.15-slim
════ 1. Failure modes (one trace per scenario, worker recreated with the scenario env) ════
── S0: healthy /mask (FAIL_CLOSED=false, TIMEOUT_MS=500, expect masked) ──
  worker env: LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED=false LANGFUSE_INGESTION_MASKING_CALLBACK_URL=http://masking:3100/mask LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS=500 (MAX_RETRIES unset = worker default)
  events_full rows=1 raw_secret_rows=0 redacted_key_rows=1 account_raw_rows=1; first row after 3s
  worker warn lines (attempt counts: 0):
    
  PASS  S0 | healthy /mask | FAIL_CLOSED=false | TIMEOUT_MS=500 | expected: masked | observed: masked
── S2: /mask-slow (2 s) (FAIL_CLOSED=false, TIMEOUT_MS=500, expect raw) ──
  worker env: LANGFUSE_INGESTION_MASKING_CALLBACK_URL=http://masking:3100/mask-slow LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS=500 LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED=false (MAX_RETRIES unset = worker default)
  events_full rows=1 raw_secret_rows=1 redacted_key_rows=0 account_raw_rows=1; first row after 2s
  worker warn lines (attempt counts: 2):
    2026-10-12T13:40:12.072Z warn 	Ingestion masking callback failed (attempt 1/2): Request timeout {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"b1bd87bfc4ccbfca7d260c100f8f4d6c","span_id":"83badf50d7421a52","trace_flags":"01"}
    2026-10-12T13:40:12.679Z warn 	Ingestion masking callback failed (attempt 2/2): Request timeout {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"b1bd87bfc4ccbfca7d260c100f8f4d6c","span_id":"83badf50d7421a52","trace_flags":"01"}
  PASS  S2 | /mask-slow (2 s) | FAIL_CLOSED=false | TIMEOUT_MS=500 | expected: raw | observed: raw
── S5a: /mask-500 (FAIL_CLOSED=false, TIMEOUT_MS=500, expect raw) ──
  worker env: LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS=500 LANGFUSE_INGESTION_MASKING_CALLBACK_URL=http://masking:3100/mask-500 LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED=false (MAX_RETRIES unset = worker default)
  events_full rows=1 raw_secret_rows=1 redacted_key_rows=0 account_raw_rows=1; first row after 2s
  worker warn lines (attempt counts: 2):
    2026-10-12T13:40:25.170Z warn 	Ingestion masking callback failed (attempt 1/2): HTTP 500: {"error":"simulated failure"} {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"38d1108d180b75ac2919d4139493894b","span_id":"6d39212aefbe9ce7","trace_flags":"01"}
    2026-10-12T13:40:25.274Z warn 	Ingestion masking callback failed (attempt 2/2): HTTP 500: {"error":"simulated failure"} {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"38d1108d180b75ac2919d4139493894b","span_id":"6d39212aefbe9ce7","trace_flags":"01"}
  PASS  S5a | /mask-500 | FAIL_CLOSED=false | TIMEOUT_MS=500 | expected: raw | observed: raw
── S1a: down: closed port (FAIL_CLOSED=false, TIMEOUT_MS=500, expect raw) ──
  worker env: LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS=500 LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED=false LANGFUSE_INGESTION_MASKING_CALLBACK_URL=http://masking:3999/mask (MAX_RETRIES unset = worker default)
  events_full rows=1 raw_secret_rows=1 redacted_key_rows=0 account_raw_rows=1; first row after 3s
  worker warn lines (attempt counts: 2):
    2026-10-12T13:40:38.872Z warn 	Ingestion masking callback failed (attempt 1/2): fetch failed {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"53a2149eb00a7ea38d585ac30e91ea67","span_id":"0b2675c6ae75370d","trace_flags":"01"}
    2026-10-12T13:40:38.975Z warn 	Ingestion masking callback failed (attempt 2/2): fetch failed {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"53a2149eb00a7ea38d585ac30e91ea67","span_id":"0b2675c6ae75370d","trace_flags":"01"}
  PASS  S1a | down: closed port | FAIL_CLOSED=false | TIMEOUT_MS=500 | expected: raw | observed: raw
  slowest raw-stored scenario appeared after 10s (floor 10 s) — dropped scenarios wait at least that long
── S3a: down: closed port (FAIL_CLOSED=true, TIMEOUT_MS=500, expect dropped) ──
  worker env: LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS=500 LANGFUSE_INGESTION_MASKING_CALLBACK_URL=http://masking:3999/mask LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED=true (MAX_RETRIES unset = worker default)
  events_full rows=0 raw_secret_rows=0 redacted_key_rows=0 account_raw_rows=0; first row after -1s
  worker warn lines (attempt counts: 2):
    2026-10-12T13:40:52.532Z warn 	Ingestion masking callback failed (attempt 1/2): fetch failed {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"bc3db365ad9d119d331c9045779595d2","span_id":"979875ea83f4d16a","trace_flags":"01"}
    2026-10-12T13:40:52.635Z warn 	Ingestion masking callback failed (attempt 2/2): fetch failed {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"bc3db365ad9d119d331c9045779595d2","span_id":"979875ea83f4d16a","trace_flags":"01"}
    2026-10-12T13:40:52.635Z warn 	Dropping OTEL event due to masking failure {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","fileKey":"events/otel/cmv5atz1v00o1mw4105dqia47/2026/10/12/13/40/1ea8baf4-ff35-4eb0-9abe-ec0e1ca748b0.json","error":"fetch failed","trace_id":"bc3db365ad9d119d331c9045779595d2","span_id":"979875ea83f4d16a","trace_flags":"01"}
  fileKey in the Dropping line: events/otel/cmv5atz1v00o1mw4105dqia47/2026/10/12/13/40/1ea8baf4-ff35-4eb0-9abe-ec0e1ca748b0.json  (object still in S3: yes)
  PASS  S3a | down: closed port | FAIL_CLOSED=true | TIMEOUT_MS=500 | expected: dropped | observed: dropped
── S4: /mask-slow (2 s) (FAIL_CLOSED=true, TIMEOUT_MS=500, expect dropped) ──
  worker env: LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS=500 LANGFUSE_INGESTION_MASKING_CALLBACK_URL=http://masking:3100/mask-slow LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED=true (MAX_RETRIES unset = worker default)
  events_full rows=0 raw_secret_rows=0 redacted_key_rows=0 account_raw_rows=0; first row after -1s
  worker warn lines (attempt counts: 2):
    2026-10-12T13:41:17.227Z warn 	Ingestion masking callback failed (attempt 1/2): Request timeout {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"1d89eac646a42ac52080a0f730c232ad","span_id":"7ad3b2019fe54715","trace_flags":"01"}
    2026-10-12T13:41:17.831Z warn 	Ingestion masking callback failed (attempt 2/2): Request timeout {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"1d89eac646a42ac52080a0f730c232ad","span_id":"7ad3b2019fe54715","trace_flags":"01"}
    2026-10-12T13:41:17.833Z warn 	Dropping OTEL event due to masking failure {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","fileKey":"events/otel/cmv5atz1v00o1mw4105dqia47/2026/10/12/13/41/40993deb-2260-427d-9221-072c8e216cd4.json","error":"Request timeout","trace_id":"1d89eac646a42ac52080a0f730c232ad","span_id":"7ad3b2019fe54715","trace_flags":"01"}
  fileKey in the Dropping line: events/otel/cmv5atz1v00o1mw4105dqia47/2026/10/12/13/41/40993deb-2260-427d-9221-072c8e216cd4.json  (object still in S3: yes)
  PASS  S4 | /mask-slow (2 s) | FAIL_CLOSED=true | TIMEOUT_MS=500 | expected: dropped | observed: dropped
── S5b: /mask-500 (FAIL_CLOSED=true, TIMEOUT_MS=500, expect dropped) ──
  worker env: LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED=true LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS=500 LANGFUSE_INGESTION_MASKING_CALLBACK_URL=http://masking:3100/mask-500 (MAX_RETRIES unset = worker default)
  events_full rows=0 raw_secret_rows=0 redacted_key_rows=0 account_raw_rows=0; first row after -1s
  worker warn lines (attempt counts: 2):
    2026-10-12T13:41:40.794Z warn 	Ingestion masking callback failed (attempt 1/2): HTTP 500: {"error":"simulated failure"} {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"88ff4236defae378cc871b3557bc6a8b","span_id":"328a167524a50832","trace_flags":"01"}
    2026-10-12T13:41:40.898Z warn 	Ingestion masking callback failed (attempt 2/2): HTTP 500: {"error":"simulated failure"} {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"88ff4236defae378cc871b3557bc6a8b","span_id":"328a167524a50832","trace_flags":"01"}
    2026-10-12T13:41:40.899Z warn 	Dropping OTEL event due to masking failure {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","fileKey":"events/otel/cmv5atz1v00o1mw4105dqia47/2026/10/12/13/41/bc535ccf-1bef-4dc7-873f-76eb4a041025.json","error":"HTTP 500: {\"error\":\"simulated failure\"}","trace_id":"88ff4236defae378cc871b3557bc6a8b","span_id":"328a167524a50832","trace_flags":"01"}
  fileKey in the Dropping line: events/otel/cmv5atz1v00o1mw4105dqia47/2026/10/12/13/41/bc535ccf-1bef-4dc7-873f-76eb4a041025.json  (object still in S3: yes)
  PASS  S5b | /mask-500 | FAIL_CLOSED=true | TIMEOUT_MS=500 | expected: dropped | observed: dropped
  (sidecar container stopped: exited)
── S1b: down: sidecar stopped (FAIL_CLOSED=false, TIMEOUT_MS=500, expect raw) ──
  worker env: LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS=500 LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED=false LANGFUSE_INGESTION_MASKING_CALLBACK_URL=http://masking:3100/mask (MAX_RETRIES unset = worker default)
  events_full rows=1 raw_secret_rows=1 redacted_key_rows=0 account_raw_rows=1; first row after 2s
  worker warn lines (attempt counts: 2):
    2026-10-12T13:42:08.088Z warn 	Ingestion masking callback failed (attempt 1/2): fetch failed {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"c104e7ced8f75cd2974e951d2e72b4c3","span_id":"1ce492f9f5e58edf","trace_flags":"01"}
    2026-10-12T13:42:08.194Z warn 	Ingestion masking callback failed (attempt 2/2): fetch failed {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"c104e7ced8f75cd2974e951d2e72b4c3","span_id":"1ce492f9f5e58edf","trace_flags":"01"}
  PASS  S1b | down: sidecar stopped | FAIL_CLOSED=false | TIMEOUT_MS=500 | expected: raw | observed: raw
── S3b: down: sidecar stopped (FAIL_CLOSED=true, TIMEOUT_MS=500, expect dropped) ──
  worker env: LANGFUSE_INGESTION_MASKING_CALLBACK_URL=http://masking:3100/mask LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS=500 LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED=true (MAX_RETRIES unset = worker default)
  events_full rows=0 raw_secret_rows=0 redacted_key_rows=0 account_raw_rows=0; first row after -1s
  worker warn lines (attempt counts: 2):
    2026-10-12T13:42:21.741Z warn 	Ingestion masking callback failed (attempt 1/2): fetch failed {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"0db806f5ec1e77a14272df478ceec445","span_id":"a9a5195ba143b33a","trace_flags":"01"}
    2026-10-12T13:42:21.849Z warn 	Ingestion masking callback failed (attempt 2/2): fetch failed {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","trace_id":"0db806f5ec1e77a14272df478ceec445","span_id":"a9a5195ba143b33a","trace_flags":"01"}
    2026-10-12T13:42:21.849Z warn 	Dropping OTEL event due to masking failure {"projectId":"cmv5atz1v00o1mw4105dqia47","orgId":"cmv5atyvw00ntmw4168ph818g","fileKey":"events/otel/cmv5atz1v00o1mw4105dqia47/2026/10/12/13/42/a6d1b460-442d-4b7a-afb6-ec49d278b2f7.json","error":"fetch failed","trace_id":"0db806f5ec1e77a14272df478ceec445","span_id":"a9a5195ba143b33a","trace_flags":"01"}
  fileKey in the Dropping line: events/otel/cmv5atz1v00o1mw4105dqia47/2026/10/12/13/42/a6d1b460-442d-4b7a-afb6-ec49d278b2f7.json  (object still in S3: yes)
  PASS  S3b | down: sidecar stopped | FAIL_CLOSED=true | TIMEOUT_MS=500 | expected: dropped | observed: dropped
════ 2c. Per-project rule: MASK_STRICT_PROJECT_IDS=<A> adds [REDACTED_ACCOUNT] for A only ════
  worker env: LANGFUSE_INGESTION_MASKING_CALLBACK_URL=http://masking:3100/mask LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS=2000 LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED=true (MAX_RETRIES unset = worker default)
  project A rows/raw_secret/redacted_key/raw_account/redacted_account = 1/0/1/0/1
  project B rows/raw_secret/redacted_key/raw_account/redacted_account = 1/0/1/1/0
PASS  2c A: rows landed: yes
PASS  2c A: [REDACTED_ACCOUNT] present: yes
PASS  2c A: raw account rows: 0
PASS  2c A: sk- redacted, raw secret rows: 0
PASS  2c B: rows landed: yes
PASS  2c B: raw account kept (positive control): yes
PASS  2c B: [REDACTED_ACCOUNT] rows: 0
PASS  2c B: sk- still redacted, raw secret rows: 0
PASS  2c B: [REDACTED_API_KEY] present: yes
  sidecar log lines for both projects:
    [mask] project=cmv5atz1v00o1mw4105dqia47 path=/mask rules=base+strict redactions=2
    [mask] project=cmv5atz6w00o8mw41e38g17o1 path=/mask rules=base redactions=1
PASS  2c sidecar logged A with rules=base+strict: 1
PASS  2c sidecar logged B with rules=base: 1
════ 2d. Legacy path: POST /api/public/ingestion with healthy masking, FAIL_CLOSED=true ════
  trace-create: HTTP 207 successes=0 errors=1 first error/body: Event type "trace-create" is not accepted by /api/public/ingestion when LANGFUSE_MIGRATION_V4_WRITE_MODE is events_only. This endpoint only accepts score events. Upgrade the client or integration to a v4-compatible SDK or OTLP ingestion path. As a temporary mi
  span-create: HTTP 207 successes=0 errors=1 first error/body: Event type "span-create" is not accepted by /api/public/ingestion when LANGFUSE_MIGRATION_V4_WRITE_MODE is events_only. This endpoint only accepts score events. Upgrade the client or integration to a v4-compatible SDK or OTLP ingestion path. As a temporary mig
  generation-create: HTTP 207 successes=0 errors=1 first error/body: Event type "generation-create" is not accepted by /api/public/ingestion when LANGFUSE_MIGRATION_V4_WRITE_MODE is events_only. This endpoint only accepts score events. Upgrade the client or integration to a v4-compatible SDK or OTLP ingestion path. As a tempora
  event-create: HTTP 207 successes=0 errors=1 first error/body: Event type "event-create" is not accepted by /api/public/ingestion when LANGFUSE_MIGRATION_V4_WRITE_MODE is events_only. This endpoint only accepts score events. Upgrade the client or integration to a v4-compatible SDK or OTLP ingestion path. As a temporary mi
  score-create: HTTP 207 successes=1 errors=0 first error/body: {"successes":[{"id":"4fe7f4bc183bd47127a72da9ca8673d6","status":201}],"errors":[]}
  accepted legacy event types: score-create
  trace-create rejected -> search over the same tables: events_full:0 events_core:0 traces:0 observations:0 scores:0
PASS  2d trace-create rejected (HTTP 207), nothing stored:  events_full:0 events_core:0 traces:0 observations:0 scores:0
  span-create rejected -> search over the same tables: events_full:0 events_core:0 traces:0 observations:0 scores:0
PASS  2d span-create rejected (HTTP 207), nothing stored:  events_full:0 events_core:0 traces:0 observations:0 scores:0
  generation-create rejected -> search over the same tables: events_full:0 events_core:0 traces:0 observations:0 scores:0
PASS  2d generation-create rejected (HTTP 207), nothing stored:  events_full:0 events_core:0 traces:0 observations:0 scores:0
  event-create rejected -> search over the same tables: events_full:0 events_core:0 traces:0 observations:0 scores:0
PASS  2d event-create rejected (HTTP 207), nothing stored:  events_full:0 events_core:0 traces:0 observations:0 scores:0
  score-create accepted -> raw secret found in: events_full:0 events_core:0 traces:0 observations:0 scores:1
PASS  2d score-create accepted: raw secret reaches ClickHouse (legacy path bypasses masking): yes
PASS  2d sidecar received no request for project A during the legacy calls (log lines before/after: 1/1): 1
════ 2e. The raw payload in the S3 event bucket ════
  bucket top-level prefixes: events/ 
  objects: events/otel/<A>/ 10  events/otel/<B>/ 1  events/<A>/ 1
  key layout (project ids replaced by <A>/<B>):
       1 events/<A>/score/<id>/<uuid>.json
       1 events/otel/<A>/2026/10/12/13/39/<uuid>.json
       4 events/otel/<A>/2026/10/12/13/40/<uuid>.json
       2 events/otel/<A>/2026/10/12/13/41/<uuid>.json
       3 events/otel/<A>/2026/10/12/13/42/<uuid>.json
       1 events/otel/<B>/2026/10/12/13/42/<uuid>.json
  object(s) holding the S0 raw secret (healthy masking, masked in ClickHouse):
    otel-A/2026/10/12/13/39/392145c9-33d3-4fce-802a-e47f6bb6776f.json
PASS  2e S0: raw secret present in S3 although ClickHouse holds the masked copy: yes
PASS  2e no masked copy written back to S3 (objects containing REDACTED_ under both projects): 0
  legacy trace-create was rejected: no S3 object expected
  legacy span-create was rejected: no S3 object expected
  legacy generation-create was rejected: no S3 object expected
  legacy event-create was rejected: no S3 object expected
  legacy score-create object(s) with the raw secret: legacy-A/score/edb80b86a73b1793/4fe7f4bc183bd47127a72da9ca8673d6.json
PASS  2e legacy score-create: raw copy in S3: yes
PASS  2e S1a (raw stored in ClickHouse): its S3 object count: 1
════ 3. Restore: worker back on the overlay defaults, sidecar running ════
  LANGFUSE_INGESTION_MASKING_CALLBACK_URL=http://masking:3100/mask
  LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS=2000
  LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED=true
PASS  sidecar state: running/healthy
PASS  worker FAIL_CLOSED is the overlay default: true
PASS  worker TIMEOUT_MS is the overlay default: 2000
PASS  sidecar has no strict project left: 

════ Scenario table ════
id   | callback                | FAIL_CLOSED | TIMEOUT_MS| expected | observed  | result
S0   | healthy /mask           | false       | 500       | masked   | masked    | PASS
S2   | /mask-slow (2 s)        | false       | 500       | raw      | raw       | PASS
S5a  | /mask-500               | false       | 500       | raw      | raw       | PASS
S1a  | down: closed port       | false       | 500       | raw      | raw       | PASS
S3a  | down: closed port       | true        | 500       | dropped  | dropped   | PASS
S4   | /mask-slow (2 s)        | true        | 500       | dropped  | dropped   | PASS
S5b  | /mask-500               | true        | 500       | dropped  | dropped   | PASS
S1b  | down: sidecar stopped   | false       | 500       | raw      | raw       | PASS
S3b  | down: sidecar stopped   | true        | 500       | dropped  | dropped   | PASS

✅ every check printed PASS
```

## Lab 13 — Project isolation under project-level RBAC (2026-10-12)

Langfuse v4.56.0 / SDK 4.17.0 / CH 26.8.22.13, EE overlay up, `events_only` write mode. Command: `labs/v4/langfuse-ee/13-ee-project-isolation.sh` (exit 0).

The script checks HTTP only: `/project/<id>` returns the same static shell for every user, and the deny happens client-side. A separate browser check on the same day used a viewer created the same way (org `NONE`, project A `VIEWER`). The organization page listed only project A. `/project/<B>/traces` rendered *"Project Not Found — The project you are trying to access does not exist or you do not have access to it."*, and `/project/<A>/traces` rendered the tracing page. The UI shows a *Create new API key* button to the viewer, but the tRPC call behind it returns 403 (row `projectApiKeys.create` below).

```text
════ 1. Organization, two projects, one API key and one trace per project ════
  org id = cmv59ziqu00l3mw417cuxyyfx
  project A id = cmv59ziwa00lbmw41vfv3btyk   trace id = 0b48d1af2e8448de42485b308bdea4f5
  project B id = cmv59zj3e00limw4141lhlahp   trace id = 2660035d188f8928e552ea9e60d6e10b
════ 2. Two local users via POST /api/auth/signup (SCIM has no password field) ════
User created
User created
════ 3. Memberships (org key): viewer = org NONE + project A VIEWER; orgadmin = org ADMIN ════
  PASS  viewer | org membership (public API) | cmv59ziqu00l3mw417cuxyyfx | expected: NONE | observed: NONE
  PASS  orgadmin | org membership (public API) | cmv59ziqu00l3mw417cuxyyfx | expected: ADMIN | observed: ADMIN
  PASS  viewer | project membership (public API) | A | expected: VIEWER | observed: VIEWER
  PASS  orgadmin | project membership (public API) | A | expected: none | observed: none
  PASS  viewer | project membership (public API) | B | expected: none | observed: none
  PASS  orgadmin | project membership (public API) | B | expected: none | observed: none
════ 4. Project list in the session (what the UI project switcher is built from) ════
  PASS  viewer | session project list | A | expected: present | observed: present
  PASS  viewer | session project list | B | expected: absent | observed: absent
  PASS  orgadmin | session project list | A | expected: present | observed: present
  PASS  orgadmin | session project list | B | expected: present | observed: present
════ 5. tRPC API behind the UI (cookie auth) ════
  PASS  viewer | tRPC traces.byId | A | expected: HTTP 200 and the trace id | observed: HTTP 200 id=0b48d1af2e8448de42485b308bdea4f5
  PASS  viewer | tRPC events.all (list) | A | expected: HTTP 200 and trace in list | observed: HTTP 200, own trace in list: 1
  PASS  viewer | tRPC traces.byId | B | expected: HTTP 4xx UNAUTHORIZED|FORBIDDEN|NOT_FOUND | observed: HTTP 401 UNAUTHORIZED
  PASS  viewer | tRPC events.all (list) | B | expected: HTTP 4xx UNAUTHORIZED|FORBIDDEN|NOT_FOUND | observed: HTTP 401 UNAUTHORIZED
  PASS  orgadmin | tRPC traces.byId | A | expected: HTTP 200 and the trace id | observed: HTTP 200 id=0b48d1af2e8448de42485b308bdea4f5
  PASS  orgadmin | tRPC events.all (list) | A | expected: HTTP 200 and trace in list | observed: HTTP 200, own trace in list: 1
  PASS  orgadmin | tRPC traces.byId | B | expected: HTTP 200 and the trace id | observed: HTTP 200 id=2660035d188f8928e552ea9e60d6e10b
  PASS  orgadmin | tRPC events.all (list) | B | expected: HTTP 200 and trace in list | observed: HTTP 200, own trace in list: 1
════ 6. Write on A (tRPC projectApiKeys.create): VIEWER must be rejected, ADMIN must succeed ════
  PASS  viewer | tRPC projectApiKeys.create (mint key) | A | expected: HTTP 403 FORBIDDEN | observed: HTTP 403 FORBIDDEN
  PASS  orgadmin | tRPC projectApiKeys.create (mint key) | A | expected: HTTP 200 and key id | observed: HTTP 200
  PASS  viewer | key left behind by the rejected call | A | expected: 0 | observed: 0
════ 7. UI pages (cookie auth; the browser check is separate) ════
  PASS  viewer | UI GET /project/cmv59ziwa00lbmw41vfv3btyk | A | expected: HTTP 200 static shell, no trace data in body | observed: HTTP 200, redirect -, 7032 bytes, body mentions own trace/name: 0
  PASS  viewer | UI GET traces | A | expected: HTTP 200 static shell, no trace data in body | observed: HTTP 200, redirect -, 7439 bytes, body mentions own trace/name: 0
  PASS  viewer | UI GET /project/cmv59zj3e00limw4141lhlahp | B | expected: HTTP 200 static shell, no trace data in body | observed: HTTP 200, redirect -, 7032 bytes, body mentions own trace/name: 0
  PASS  viewer | UI GET traces | B | expected: HTTP 200 static shell, no trace data in body | observed: HTTP 200, redirect -, 7439 bytes, body mentions own trace/name: 0
  PASS  orgadmin | UI GET /project/cmv59ziwa00lbmw41vfv3btyk | A | expected: HTTP 200 static shell, no trace data in body | observed: HTTP 200, redirect -, 7032 bytes, body mentions own trace/name: 0
  PASS  orgadmin | UI GET traces | A | expected: HTTP 200 static shell, no trace data in body | observed: HTTP 200, redirect -, 7439 bytes, body mentions own trace/name: 0
  PASS  orgadmin | UI GET /project/cmv59zj3e00limw4141lhlahp | B | expected: HTTP 200 static shell, no trace data in body | observed: HTTP 200, redirect -, 7032 bytes, body mentions own trace/name: 0
  PASS  orgadmin | UI GET traces | B | expected: HTTP 200 static shell, no trace data in body | observed: HTTP 200, redirect -, 7439 bytes, body mentions own trace/name: 0
════ 8. Public API: project API keys are scoped to their own project ════
  PASS  key A | FINDING public GET /traces/<own trace> | A | expected: 404 events_only (endpoint off) | observed: HTTP 404 events_only
  PASS  key B | FINDING public GET /traces/<own trace> | B | expected: 404 events_only (endpoint off) | observed: HTTP 404 events_only
  PASS  key A | public v2/observations?traceId=<A trace> | A | expected: 1 observation | observed: 1
  PASS  key A | public v2/observations?traceId=<B trace> | B | expected: 0 observations | observed: 0
  PASS  key B | public v2/observations?traceId=<B trace> | B | expected: 1 observation (control) | observed: 1
  PASS  key A | public v2/observations (unfiltered list) | A | expected: >=1 row, 0 from the other project | observed: 1 rows, 0 foreign
  PASS  key B | public v2/observations (unfiltered list) | B | expected: >=1 row, 0 from the other project | observed: 1 rows, 0 foreign

════ Result table ════
actor     surface                                    project                    expected                                      observed                                                           result
viewer    org membership (public API)                cmv59ziqu00l3mw417cuxyyfx  NONE                                          NONE                                                               PASS
orgadmin  org membership (public API)                cmv59ziqu00l3mw417cuxyyfx  ADMIN                                         ADMIN                                                              PASS
viewer    project membership (public API)            A                          VIEWER                                        VIEWER                                                             PASS
orgadmin  project membership (public API)            A                          none                                          none                                                               PASS
viewer    project membership (public API)            B                          none                                          none                                                               PASS
orgadmin  project membership (public API)            B                          none                                          none                                                               PASS
viewer    session project list                       A                          present                                       present                                                            PASS
viewer    session project list                       B                          absent                                        absent                                                             PASS
orgadmin  session project list                       A                          present                                       present                                                            PASS
orgadmin  session project list                       B                          present                                       present                                                            PASS
viewer    tRPC traces.byId                           A                          HTTP 200 and the trace id                     HTTP 200 id=0b48d1af2e8448de42485b308bdea4f5                       PASS
viewer    tRPC events.all (list)                     A                          HTTP 200 and trace in list                    HTTP 200, own trace in list: 1                                     PASS
viewer    tRPC traces.byId                           B                          HTTP 4xx UNAUTHORIZED|FORBIDDEN|NOT_FOUND     HTTP 401 UNAUTHORIZED                                              PASS
viewer    tRPC events.all (list)                     B                          HTTP 4xx UNAUTHORIZED|FORBIDDEN|NOT_FOUND     HTTP 401 UNAUTHORIZED                                              PASS
orgadmin  tRPC traces.byId                           A                          HTTP 200 and the trace id                     HTTP 200 id=0b48d1af2e8448de42485b308bdea4f5                       PASS
orgadmin  tRPC events.all (list)                     A                          HTTP 200 and trace in list                    HTTP 200, own trace in list: 1                                     PASS
orgadmin  tRPC traces.byId                           B                          HTTP 200 and the trace id                     HTTP 200 id=2660035d188f8928e552ea9e60d6e10b                       PASS
orgadmin  tRPC events.all (list)                     B                          HTTP 200 and trace in list                    HTTP 200, own trace in list: 1                                     PASS
viewer    tRPC projectApiKeys.create (mint key)      A                          HTTP 403 FORBIDDEN                            HTTP 403 FORBIDDEN                                                 PASS
orgadmin  tRPC projectApiKeys.create (mint key)      A                          HTTP 200 and key id                           HTTP 200                                                           PASS
viewer    key left behind by the rejected call       A                          0                                             0                                                                  PASS
viewer    UI GET /project/cmv59ziwa00lbmw41vfv3btyk  A                          HTTP 200 static shell, no trace data in body  HTTP 200, redirect -, 7032 bytes, body mentions own trace/name: 0  PASS
viewer    UI GET traces                              A                          HTTP 200 static shell, no trace data in body  HTTP 200, redirect -, 7439 bytes, body mentions own trace/name: 0  PASS
viewer    UI GET /project/cmv59zj3e00limw4141lhlahp  B                          HTTP 200 static shell, no trace data in body  HTTP 200, redirect -, 7032 bytes, body mentions own trace/name: 0  PASS
viewer    UI GET traces                              B                          HTTP 200 static shell, no trace data in body  HTTP 200, redirect -, 7439 bytes, body mentions own trace/name: 0  PASS
orgadmin  UI GET /project/cmv59ziwa00lbmw41vfv3btyk  A                          HTTP 200 static shell, no trace data in body  HTTP 200, redirect -, 7032 bytes, body mentions own trace/name: 0  PASS
orgadmin  UI GET traces                              A                          HTTP 200 static shell, no trace data in body  HTTP 200, redirect -, 7439 bytes, body mentions own trace/name: 0  PASS
orgadmin  UI GET /project/cmv59zj3e00limw4141lhlahp  B                          HTTP 200 static shell, no trace data in body  HTTP 200, redirect -, 7032 bytes, body mentions own trace/name: 0  PASS
orgadmin  UI GET traces                              B                          HTTP 200 static shell, no trace data in body  HTTP 200, redirect -, 7439 bytes, body mentions own trace/name: 0  PASS
key A     FINDING public GET /traces/<own trace>     A                          404 events_only (endpoint off)                HTTP 404 events_only                                               PASS
key B     FINDING public GET /traces/<own trace>     B                          404 events_only (endpoint off)                HTTP 404 events_only                                               PASS
key A     public v2/observations?traceId=<A trace>   A                          1 observation                                 1                                                                  PASS
key A     public v2/observations?traceId=<B trace>   B                          0 observations                                0                                                                  PASS
key B     public v2/observations?traceId=<B trace>   B                          1 observation (control)                       1                                                                  PASS
key A     public v2/observations (unfiltered list)   A                          >=1 row, 0 from the other project             1 rows, 0 foreign                                                  PASS
key B     public v2/observations (unfiltered list)   B                          >=1 row, 0 from the other project             1 rows, 0 foreign                                                  PASS

✅ all 36 checks passed (org cmv59ziqu00l3mw417cuxyyfx, projects A=cmv59ziwa00lbmw41vfv3btyk B=cmv59zj3e00limw4141lhlahp)
exit=0
```

## Lab 14 — Client-side field encryption (`mask_otel_spans`) (2026-10-12)

Langfuse v4.56.0 / SDK 4.17.0 / CH 26.8.22.13, EE overlay up, `events_only` write mode. Command: `labs/v4/langfuse-ee/14-field-encryption.sh` (exit 0).

```text
════ 1. Setup: org, projects A and B, API keys, one AES-256 key per project ════
  org cmv59otog00cvmw41xh41z6dc  project A cmv59otua00d3mw411trfmoa6  project B cmv59ou1100damw41ld4qjy5k
  AES keys: 2 written to _base/.env.field-keys, mode 600
════ 2. Send: 2 traces with the hook, 1 control trace without ════
  span 'answer' attribute keys: ['langfuse.observation.input', 'langfuse.observation.metadata.account_no', 'langfuse.observation.model.name', 'langfuse.observation.output', 'langfuse.observation.type', 'langfuse.trace.metadata.account_no', 'langfuse.trace.name']
  span 'transfer-status' attribute keys: ['langfuse.internal.is_app_root', 'langfuse.observation.input', 'langfuse.observation.output', 'langfuse.observation.type', 'langfuse.trace.input', 'langfuse.trace.metadata.account_no', 'langfuse.trace.name', 'langfuse.trace.output']
  hook traces: de1f1135ae147c60540da456b93fa80f e6f040a0bbca38ac1abe68d56f3294a6
  control trace: 5729c9e779e8466603be643068054403
════ 3. ClickHouse: plaintext of the encrypted fields must be absent, the control must be present ════
  events_full rows for the 3 traces: 6 (expect 6 = 3 traces x 2 observations)
PASS  events_full hook rows: 4
PASS  events_full plaintext input marker in hook rows: 0
PASS  events_full plaintext account_no in hook rows: 0
PASS  events_full rows holding enc:v1:: 4
PASS  events_full control rows: 2
PASS  events_full control input marker in plaintext (positive control): 2
PASS  events_full control account_no in plaintext (positive control): 2
PASS  events_full plaintext OUTPUT marker in hook rows (output was not encrypted): 4
PASS  events_core hook rows: 4
PASS  events_core plaintext input marker in hook rows: 0
PASS  events_core plaintext account_no in hook rows: 0
PASS  events_core rows holding enc:v1:: 4
PASS  events_core control rows: 2
PASS  events_core control input marker in plaintext (positive control): 2
PASS  events_core control account_no in plaintext (positive control): 2
PASS  events_core plaintext OUTPUT marker in hook rows (output was not encrypted): 4
PASS  events_core_mv hook rows: 4
PASS  events_core_mv plaintext input marker in hook rows: 0
PASS  events_core_mv plaintext account_no in hook rows: 0
PASS  events_core_mv rows holding enc:v1:: 4
PASS  events_core_mv control rows: 2
PASS  events_core_mv control input marker in plaintext (positive control): 2
PASS  events_core_mv control account_no in plaintext (positive control): 2
PASS  events_core_mv plaintext OUTPUT marker in hook rows (output was not encrypted): 4
INFO  traces: no rows of this run (table is not written by this stack) - nothing to check
INFO  observations: no rows of this run (table is not written by this stack) - nothing to check
INFO  observations_pid_tid_sorting: no rows of this run (table is not written by this stack) - nothing to check
INFO  observations_batch_staging: no rows of this run (table is not written by this stack) - nothing to check
════ 4. What the UI shows: the public API returns the stored values ════
  GET /api/public/v2/observations?traceId=<hook trace>&fields=core,basic,io,metadata:
{"name":"answer","input":"enc:v1:cmv59otua00d3mw411trfmoa6:d610IJaYdRzss2KKR","account_no":"enc:v1:cmv59otua00d3mw411trfmoa6:FUCEH_J","output":"Your transfer ENCMARK-OUT-1791810468 is complete"}
{"name":"transfer-status","input":"enc:v1:cmv59otua00d3mw411trfmoa6:dQfxlbO-fJuE8Dx_A","account_no":"enc:v1:cmv59otua00d3mw411trfmoa6:bYxR8Hv","output":"Your transfer ENCMARK-OUT-1791810468 is complete"}
PASS  API observations whose input is ciphertext: 2
PASS  API observations whose metadata.account_no is ciphertext: 2
PASS  API observations holding the plaintext input marker: 0
════ 5. Reader: decrypt with the project's key (14-decrypt-fields.py) ════
  ── trace de1f1135ae147c60540da456b93fa80f: 2 observations
     child observation answer: input = enc:v1:cmv59otua00d3mw411trfmoa6:d610IJaYdRzss2KKR…  account_no = enc:v1:cmv59otua00d3mw411trfmoa6:FUCEH_J…
  PASS  child observation answer input is ciphertext: enc:v1:cmv59otua00d3mw411trfmoa6:d610IJa…
  PASS  child observation answer input decrypts to the expected plaintext: decrypted value equals expected
  PASS  child observation answer input with another project's key fails: InvalidTag
  PASS  child observation answer metadata.account_no is ciphertext: enc:v1:cmv59otua00d3mw411trfmoa6:FUCEH_J…
  PASS  child observation answer metadata.account_no decrypts to the expected plaintext: decrypted value equals expected
  PASS  child observation answer output is plaintext (search control): Your transfer ENCMARK-OUT-1791810468 is complete
     root observation transfer-status: input = enc:v1:cmv59otua00d3mw411trfmoa6:dQfxlbO-fJuE8Dx_A…  account_no = enc:v1:cmv59otua00d3mw411trfmoa6:bYxR8Hv…
  PASS  root observation transfer-status input is ciphertext: enc:v1:cmv59otua00d3mw411trfmoa6:dQfxlbO…
  PASS  root observation transfer-status input decrypts to the expected plaintext: decrypted value equals expected
  PASS  root observation transfer-status input with another project's key fails: InvalidTag
  PASS  root observation transfer-status metadata.account_no is ciphertext: enc:v1:cmv59otua00d3mw411trfmoa6:bYxR8Hv…
  PASS  root observation transfer-status metadata.account_no decrypts to the expected plaintext: decrypted value equals expected
  PASS  root observation transfer-status output is plaintext (search control): Your transfer ENCMARK-OUT-1791810468 is complete
  ── trace e6f040a0bbca38ac1abe68d56f3294a6: 2 observations
     child observation answer: input = enc:v1:cmv59otua00d3mw411trfmoa6:e2Mhx_mzHkMs_1sOb…  account_no = enc:v1:cmv59otua00d3mw411trfmoa6:CflIHI3…
  PASS  child observation answer input is ciphertext: enc:v1:cmv59otua00d3mw411trfmoa6:e2Mhx_m…
  PASS  child observation answer input decrypts to the expected plaintext: decrypted value equals expected
  PASS  child observation answer input with another project's key fails: InvalidTag
  PASS  child observation answer metadata.account_no is ciphertext: enc:v1:cmv59otua00d3mw411trfmoa6:CflIHI3…
  PASS  child observation answer metadata.account_no decrypts to the expected plaintext: decrypted value equals expected
  PASS  child observation answer output is plaintext (search control): Your transfer ENCMARK-OUT-1791810468 is complete
     root observation transfer-status: input = enc:v1:cmv59otua00d3mw411trfmoa6:bs8HxkYjgZOIwtQgN…  account_no = enc:v1:cmv59otua00d3mw411trfmoa6:DKVg2cf…
  PASS  root observation transfer-status input is ciphertext: enc:v1:cmv59otua00d3mw411trfmoa6:bs8HxkY…
  PASS  root observation transfer-status input decrypts to the expected plaintext: decrypted value equals expected
  PASS  root observation transfer-status input with another project's key fails: InvalidTag
  PASS  root observation transfer-status metadata.account_no is ciphertext: enc:v1:cmv59otua00d3mw411trfmoa6:DKVg2cf…
  PASS  root observation transfer-status metadata.account_no decrypts to the expected plaintext: decrypted value equals expected
  PASS  root observation transfer-status output is plaintext (search control): Your transfer ENCMARK-OUT-1791810468 is complete
PASS  reader exit status: 0
PASS  reader PASS lines (2 traces x 2 observations x 6 checks): 24
════ 6. UI search: tRPC events.all with searchType input/output (the v4 table's search) ════
PASS  search input 'ENCMARK-IN-1791810468': hook-trace hits (ciphertext): 0
PASS  search input 'ENCMARK-IN-1791810468': control hits (positive control): 2
PASS  search output 'ENCMARK-OUT-1791810468': hook-trace hits (plaintext output): 4
PASS  search output 'ENCMARK-OUT-1791810468': control hits: 2
PASS  search content 'ENCMARK-IN-1791810468': hook-trace hits: 0
PASS  search content 'ENCMARK-IN-1791810468': control hits (positive control): 2
════ 7. LLM-as-a-judge: what {{input}} resolves to (no model is called) ════
  events.js:  const getTraceById = async (params) => {
  events.js:      if (env_1.env.LANGFUSE_MIGRATION_V4_WRITE_MODE !== "events_only") {
  events.js:          return (0, traces_1.getTraceByIdFromTracesTable)(params);
  events.js:      }
  events.js:      return (0, exports.getTraceByIdFromEventsTable)(params);
  events.js:  };
  evalService.js:1136:                value: parseDatabaseRowValue(trace, mapping),
  stored root input (what {{input}} gets): enc:v1:cmv59otua00d3mw411trfmoa6:dQfxlbO-fJuE8Dx_AkvNmkGNYl6hjyDbT1crw...
PASS  evaluator {{input}} is ciphertext: yes

✅ All checks PASS (run 1791810468).
```

## Lab 14b — Managed LLM-as-a-judge on encrypted fields (2026-10-13)

Langfuse v4.56.0 / SDK 4.17.0 / CH 26.8.22.13, real Anthropic `claude-haiku-4-5` judge calls (approved; 9 in total over 3 runs). Command: `labs/v4/langfuse-ee/14-judge-encrypted.sh` (run 3, exit 0). Run 1 failed on a read-back bug in the script's cleanup check (`jq` `false // …`); run 2 used the first prompt wording, and the judge scored the plaintext control 0 ("a reference code or identifier rather than readable natural language"). The prompt was reworded for run 3. The encrypted traces scored 0 in all 6 judgments of the three runs.

```text
════ 1. Setup: org, project, API key, AES-256 key ════
  org cmv5dshvz001xmw3tfuo37hhv  project cmv5dsi2c0025mw3tl2j39chk  (AES key written to _base/.env.field-keys, never printed)
════ 2. Judge: LLM connection, evaluator (input only), rule on root observations ════
  LLM connection: {"provider":"anthropic","adapter":"anthropic","withDefaultModels":true}
  evaluator cmv5dsj1o002fmw3tunea0p9l  rule cmv5dsj3n002kmw3ths3oyysn  enabled=true  model claude-haiku-4-5
════ 3. Send: 2 traces with the hook (encrypted input), 1 control trace without ════
  hook traces: 22581f31a9e49f20bf5e667c481aa529 ce3a5be0232ea6ba8d1ac3cde1e4d974
  control trace: 3e1a58f84ad059b1e8442c8d06fd61b7
════ 4. Wait (max 3 min) for EVAL scores on the 3 root observations ════
  traces with an EVAL score: 3 of 3
  encrypted 22581f31a9e49f20bf5e667c481aa529  value=0  source=EVAL
      reasoning: The question text is encrypted ciphertext (marked as enc:v1 format) and is not readable as a natural language question.
  encrypted ce3a5be0232ea6ba8d1ac3cde1e4d974  value=0  source=EVAL
      reasoning: The question text is encrypted (prefixed with 'enc:v1:' and contains encoded content) and therefore unreadable.
  control 3e1a58f84ad059b1e8442c8d06fd61b7  value=1  source=EVAL
      reasoning: This is a readable question asking about transfer status, with a reference code ENCMARK-IN-1791817357-CTRL included.
PASS  EVAL scores on the 3 root observations: 3
PASS  encrypted trace 22581f31 judged unreadable (value 0): 0
PASS  encrypted trace ce3a5be0 judged unreadable (value 0): 0
PASS  control trace judged a transfer question (value 1, positive control): 1
PASS  control reasoning mentions a transfer: 1
════ 5. The prompt the judge actually sent (its own trace, environment langfuse-llm-as-a-judge) ════
  judge traces in this project: 3; observations by type:
    GENERATION	3
PASS  stored input of 22581f31 is ciphertext: yes
PASS  judge prompt for 22581f31 holds that exact ciphertext: 1
      judge sent: Question: enc:v1:cmv5dsi2c0025mw3tl2j39chk:fwb32J_OyAQoHnRYjWRgYDu_pThKJI5hrmkziyOCIwOWxHQ
PASS  stored input of ce3a5be0 is ciphertext: yes
PASS  judge prompt for ce3a5be0 holds that exact ciphertext: 1
      judge sent: Question: enc:v1:cmv5dsi2c0025mw3tl2j39chk:cq80mzxxKPPo2wKz3FD_NLeuXCYpkcVJuoWbYCM5AbqBziS
PASS  judge prompt for the control holds the plaintext marker (positive control): 1
      judge sent: Question: Transfer status for ENCMARK-IN-1791817357-CTRL\\nScore 1 if the text is a readabl
PASS  judge prompts holding a plaintext marker without -CTRL (i.e. from an encrypted trace): 0
  judge calls made by this run (generation observations): 3
════ 6. Cleanup ════
  cleanup: rule cmv5dsj3n002kmw3ths3oyysn enabled=false (leaves the LLM connection in place)

✅ All checks PASS (run 1791817357).
EXIT 0
```

## Lab 15 — ClickHouse OSS row policy on `project_id` (2026-10-12)

Langfuse v4.56.0 / SDK 4.17.0 / CH 26.8.22.13, EE overlay up, `events_only` write mode. Command: `labs/v4/langfuse-ee/15-ch-row-policy.sh` (exit 0).

```text
════ 0. Server and the tables that carry project_id ════
  version: 26.8.22.13
  tables with project_id (12): blob_storage_file_log dataset_run_items_rmt events_core events_full observations observations_batch_staging observations_pid_tid_sorting scores topic_assignments topic_facet_summaries topics traces
  views with project_id  (4): analytics_observations analytics_scores analytics_traces events_core_mv   (not given a policy; they read the tables above)
  tables WITHOUT project_id: schema_migrations
════ 1. Organization + two projects (A, B) + keys ════
  project A id = cmv59oggd00cfmw417t7fiq7i
  project B id = cmv59oglh00cmmw41wg6vw9df
════ 2. Send traces to A and B through the SDK (OTLP) ════
  sent 3 traces (+3 scores) to project A
  sent 3 traces (+3 scores) to project B
▶ Waiting for both projects' rows in events_full and scores (up to 120 s)…
  events_full: A=6 B=6   scores: A=3 B=3
════ 3. Which tables hold rows for both projects (positive control, as clickhouse) ════
  tested   blob_storage_file_log  (A=3, B=3)
  skipped  dataset_run_items_rmt  (A=0, B=0: no rows for one project, a 0 here would prove nothing)
  tested   events_core  (A=6, B=6)
  tested   events_full  (A=6, B=6)
  skipped  observations  (A=0, B=0: no rows for one project, a 0 here would prove nothing)
  skipped  observations_batch_staging  (A=0, B=0: no rows for one project, a 0 here would prove nothing)
  skipped  observations_pid_tid_sorting  (A=0, B=0: no rows for one project, a 0 here would prove nothing)
  tested   scores  (A=3, B=3)
  skipped  topic_assignments  (A=0, B=0: no rows for one project, a 0 here would prove nothing)
  skipped  topic_facet_summaries  (A=0, B=0: no rows for one project, a 0 here would prove nothing)
  skipped  topics  (A=0, B=0: no rows for one project, a 0 here would prove nothing)
  skipped  traces  (A=0, B=0: no rows for one project, a 0 here would prove nothing)
  skipped  analytics_observations  (A=0, B=0: no rows for one project, a 0 here would prove nothing)
  skipped  analytics_scores  (A=0, B=0: no rows for one project, a 0 here would prove nothing)
  skipped  analytics_traces  (A=0, B=0: no rows for one project, a 0 here would prove nothing)
════ 4. Create analyst_a and a row policy on every project_id table ════
  clickhouse: access_management = 0 (users.d/default-user.xml)
  PASS  clickhouse cannot create users (Langfuse's account has no access management)  [ACCESS_DENIED]
  → creating a temporary admin user lab_rp_admin through users.d (ClickHouse reloads it, no restart)
  12 policies named rp_analyst_a; one of them:
    Row 1:
    ──────
    database:      default
    table:         events_full
    select_filter: project_id = 'cmv59oggd00cfmw417t7fiq7i'
    apply_to_list: ['analyst_a']
════ 5. As analyst_a: only project A; as clickhouse: both ════
  PASS  blob_storage_file_log: clickhouse sees A and B (control)  [cmv59oggd00cfmw417t7fiq7i:3 cmv59oglh00cmmw41wg6vw9df:3]
  PASS  blob_storage_file_log: analyst_a GROUP BY project_id sees only A  [cmv59oggd00cfmw417t7fiq7i:3]
  PASS  blob_storage_file_log: analyst_a WHERE project_id='B' returns 0  [0]
  PASS  events_core: clickhouse sees A and B (control)  [cmv59oggd00cfmw417t7fiq7i:6 cmv59oglh00cmmw41wg6vw9df:6]
  PASS  events_core: analyst_a GROUP BY project_id sees only A  [cmv59oggd00cfmw417t7fiq7i:6]
  PASS  events_core: analyst_a WHERE project_id='B' returns 0  [0]
  PASS  events_full: clickhouse sees A and B (control)  [cmv59oggd00cfmw417t7fiq7i:6 cmv59oglh00cmmw41wg6vw9df:6]
  PASS  events_full: analyst_a GROUP BY project_id sees only A  [cmv59oggd00cfmw417t7fiq7i:6]
  PASS  events_full: analyst_a WHERE project_id='B' returns 0  [0]
  PASS  scores: clickhouse sees A and B (control)  [cmv59oggd00cfmw417t7fiq7i:3 cmv59oglh00cmmw41wg6vw9df:3]
  PASS  scores: analyst_a GROUP BY project_id sees only A  [cmv59oggd00cfmw417t7fiq7i:3]
  PASS  scores: analyst_a WHERE project_id='B' returns 0  [0]
════ 6. Why clickhouse is unaffected (settings) ════
  system.settings (per query, user-level):
    apply_row_policy_after_final	1
  system.server_settings rows matching row_polic|users_without: 0  (the server option is not listed there)
  config.xml (<access_control_improvements>), effective copy first:
    /var/lib/clickhouse/preprocessed_configs/config.xml:872:        <throw_on_unmatched_row_policies>false</throw_on_unmatched_row_policies>
    /var/lib/clickhouse/preprocessed_configs/config.xml:878:        <users_without_row_policies_can_read_rows>true</users_without_row_policies_can_read_rows>
    /etc/clickhouse-server/config.xml:866:        <throw_on_unmatched_row_policies>false</throw_on_unmatched_row_policies>
    /etc/clickhouse-server/config.xml:872:        <users_without_row_policies_can_read_rows>true</users_without_row_policies_can_read_rows>
  clickhouse has policies applied to it: 0 (policy lists only analyst_a)
  PASS  users_without_row_policies_can_read_rows is true: a user the policy does not name reads all rows  [true]
════ 7. Langfuse itself still works after the policies exist ════
  control — API before the policy was created: A=6 B=6
  PASS  control: the API returned B's 6 observations BEFORE the policies existed  [6]
  PASS  public API GET /api/public/v2/observations, project B, AFTER the policies  [6]
  PASS  public API GET /api/public/v2/observations, project A, AFTER the policies  [6]
  sent 1 traces (+1 scores) to project B
  PASS  a trace sent AFTER the policies exist is ingested (worker insert) and served to B  [8]
  PASS  …and ClickHouse holds 8 events_full rows for B (clickhouse)  [8]
════ 8. Escape hatches as analyst_a ════
  PASS  merge('default','^events_full$'): no B rows  [analyst: cmv59oggd00cfmw417t7fiq7i:6 | control: cmv59oggd00cfmw417t7fiq7i:6 cmv59oglh00cmmw41wg6vw9df:8 ]
  PASS  MV target events_core directly: no B rows  [analyst: cmv59oggd00cfmw417t7fiq7i:6 | control: cmv59oggd00cfmw417t7fiq7i:6 cmv59oglh00cmmw41wg6vw9df:8 ]
  PASS  remote('localhost') without credentials: refused  [Code: 497. DB::Exception: Received from localhost:9000. DB::Exception: analyst_a: Not enough privileges. To execute this query, it's necessary to have the grant READ ON REMOTE. (ACCESS_DENIED)]
  PASS  remote('localhost') with the analyst's own credentials: refused  [Code: 497. DB::Exception: Received from localhost:9000. DB::Exception: analyst_a: Not enough privileges. To execute this query, it's necessary to have the grant READ ON REMOTE. (ACCESS_DENIED)]
  PASS  FINAL: no B rows  [analyst: cmv59oggd00cfmw417t7fiq7i:6 | control: cmv59oggd00cfmw417t7fiq7i:6 cmv59oglh00cmmw41wg6vw9df:8 ]
  PASS  PREWHERE on another column: no B rows  [analyst: cmv59oggd00cfmw417t7fiq7i:6 | control: cmv59oggd00cfmw417t7fiq7i:6 cmv59oglh00cmmw41wg6vw9df:8 ]
  PASS  remote('localhost') without credentials, REMOTE granted: no B rows  [analyst: cmv59oggd00cfmw417t7fiq7i:6 | control: cmv59oggd00cfmw417t7fiq7i:6 cmv59oglh00cmmw41wg6vw9df:8 ]
  PASS  remote('localhost') with the analyst's own credentials, REMOTE granted: no B rows  [analyst: cmv59oggd00cfmw417t7fiq7i:6 | control: cmv59oggd00cfmw417t7fiq7i:6 cmv59oglh00cmmw41wg6vw9df:8 ]
  PASS  system.parts (row counts of the whole table): refused  [Code: 497. DB::Exception: Received from localhost:9000. DB::Exception: analyst_a: Not enough privileges. To execute this query, it's necessary to have the grant SELECT ON system.parts. (ACCESS_DENIED)]
  (system.parts is not a row-policy question: it carries no project_id. It is blocked or open by GRANT, shown above.)
════ 9. CREATE MASKING POLICY on OSS ════
  version: 26.8.22.13
    Received exception from server (version 26.8.22):
    Code: 344. DB::Exception: Received from localhost:9000. DB::Exception: Masking Policies are available only in ClickHouse Cloud. (SUPPORT_IS_DISABLED)
    (query: CREATE MASKING POLICY mp_probe ON default.events_full UPDATE input = '***' TO analyst_a)
  PASS  CREATE MASKING POLICY is refused on this server  [Code: 344. Masking Policies are available only in ClickHouse Cloud. (SUPPORT_IS_DISABLED)]
  PASS  no masking policy was created (control: row policies exist, masking ones do not)  [0]

✅ ROW POLICY VERDICT: PASS (0 failed checks)
▶ Cleanup: row policies left = 0, users named analyst_a left = 0
▶ Cleanup: temporary admin user definition removed (/etc/clickhouse-server/users.d/zz-15-row-policy-admin.xml); ClickHouse drops it on its next config reload
```

---

## Findings & gotchas (blog-worthy)

1. **v4 writes somewhere else.** Observations land in `events_full` / `events_core`; the v3 `traces` / `observations` tables still exist and get **0 rows**. Any v3-era query returns empty results instead of an error. That is why lab 03 prints the v3 row counts next to the v4 ones.

2. **A negative check needs a positive control.** "0 leaked secrets" on an empty table is not a result. The masking proof now ends in a verdict that requires PII rows and placeholders to exist. It was shown to FAIL on an empty table on 2026-10-10. On 2026-10-02 it was also shown to FAIL on six other planted cases (leaks, a missing placeholder, no PII rows); those were not re-run since. Masking stays provable in the warehouse: 0 leaks, 24 masked rows, 108 redactions.

3. **No joins for trace context.** v4 writes `trace_name`, `user_id`, `session_id`, `tags` and metadata onto every observation row. The roots are `is_app_root = true`. Cost by tier or user is now a single-table `GROUP BY`.

4. **Cost depends on the usage key names.** Langfuse prices usage keys that match the model's price definition. Measured on 4.48.0 with a throwaway stack on 2026-10-02 (not re-run since):
   - `gpt-4o-mini` with `input` / `output` → priced
   - `gpt-4o-mini` with `input_tokens` / `output_tokens` → `total_cost = 0`
   - `claude-haiku-4-5` → priced with either
   - `claude-3-5-sonnet-20241022` (used before that run) → no price definition at all

   The generator now sends `input` / `output` and simulates only priced models. On 2026-10-10 every model in the lab-04 cost table came out priced.

5. **ReplacingMergeTree, reconsidered.** The v4 events table is "mostly immutable": raw rows equalled `FINAL` (158 = 158), where v3's `traces` had 41 raw rows for 40 traces. Keep reading with `FINAL` + `is_deleted = 0` anyway; retention deletes and updates still create versions.

6. **Pin, then re-check the drift on each pin.** On v3.197.1 the integration API rejected `PARQUET` with HTTP 400 although the public OpenAPI spec listed it. On 4.56.0 it is accepted, with the `OBSERVATIONS_V2` source. The finding that lasts is the habit: pin the image, and validate the API surface against the *running* version.

7. **Real model calls are just another OTel producer.** The official Anthropic SDK, instrumented by `opentelemetry-instrumentation-anthropic`, lands as `GENERATION` rows. They carry the dated model ID `claude-haiku-4-5-20251001`, which Langfuse's model definition matches, so they are priced. Lab 02's 5 real calls were priced by Langfuse at **$0.001303**. The eval lab's real calls ran in the same session; their cost was not summed here.

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
   - 환경: Langfuse v4.56.0 / ClickHouse 26.8.22.13 / SDK 4.17.0.
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
   - 핵심은 **판정(verdict)**이다. 빈 테이블에서는 FAIL이 나오는 것을 2026-10-10에 다시 확인했다. 그 밖의 계획된 6가지 경우(누출, 플레이스홀더 없음, PII 행 없음)는 2026-10-02 실행에서 확인했고 이번에는 다시 돌리지 않았다. FAIL이 나와야 PASS를 믿을 수 있다. (발견 #2)
7. **프롬프트 거버넌스** — `production` 라벨이 v1에서 v2로 **이동**하는 것을 보면, 왜 protected label이 필요한지 이어진다. (발견 #8)
8. **데이터 반출: Parquet와 ClickHouse 라운드트립**
   - `INSERT INTO FUNCTION s3(...)`로 쓰고 되읽어 **182 == 182**를 확인한다. archive-then-delete 패턴이다.
   - v3.197.1에서 400이던 `PARQUET`가 4.56.0에서는 받아들여진다. 교훈은 버전을 고정하고, 고정할 때마다 실행 중인 버전으로 다시 확인하는 것이다. (발견 #6)
9. **실제 모델 호출** — Anthropic SDK를 OTel로 계측하면 GENERATION 행이 남고 비용도 계산된다. 랩 02의 실제 호출 5건은 Langfuse 가격 기준 $0.001303이었다(eval 랩의 실제 호출 비용은 합산하지 않았다). (발견 #7)
10. **마무리** — 셀프호스팅 Langfuse는 사실상 실전 ClickHouse 애플리케이션이다. ClickHouse가 있으면 관측성과 컴플라이언스(마스킹·보존·반출)를 *데이터로* 증명할 수 있다.

**추천 코드/캡처:**
- v3 테이블 0행과 v4 테이블 행 수
- 마스킹 판정 표(0–G; 0만 2026-10-10에 재실행)
- usage 키별 비용 비교(2026-10-02 측정)
- `PARQUET` 응답(v3 400 → v4 200)
- `s3()` 182 == 182

위 로그에서 그대로 인용할 수 있습니다. 단, 2026-10-02 측정으로 표시한 항목은 이번 실행에서 다시 돌리지 않았습니다.

---

*Generated 2026-10-10 by running every script in this directory end to end on the pinned stack (Langfuse v4.56.0 / SDK 4.17.0 / ClickHouse 26.8.22.13). The console blocks are trimmed excerpts of that run's logs.*
