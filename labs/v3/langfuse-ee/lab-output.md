# Langfuse-on-ClickHouse Enterprise Workshop — Full Run Log & Blog Source

A complete, captured end-to-end run of every lab in [`labs/v3/langfuse-ee/`](./README.md) — OSS track (01–04) and the full Enterprise track (05–11). This is the raw material for a tech blog: real commands, real output, and the findings that surfaced while running it.

> Language note: the run log below is English (the console output is language-neutral). A ready-to-use **Korean blog outline (한국어 블로그 아웃라인)** is at the end.

> Scope of this run (2026-10-06): every step ran **offline**. The v3 track makes no model call as long as `OPENAI_API_KEY` is empty, and it was empty; the OpenAI real-call path was **not** run. Labs 05–11 ran with a real enterprise licence key (the value is never shown). Where this file mentions the earlier run (2026-07-26, Langfuse v3.197.1 / SDK 3.7.0 / ClickHouse 25.11.2.24), it says so and marks it as not re-run.

---

## TL;DR

- Self-hosted **Langfuse v3.225.11** stores every trace/observation/score in **ClickHouse 26.8.18.2**. We stood the stack up, pushed traces with the Python SDK, and ran cost/latency/quality analytics straight on ClickHouse.
- Then we activated an **Enterprise license** and ran the seven Enterprise labs (05–11) end-to-end — the highlight being **server-side data masking, *proven* absent in ClickHouse with SQL**, and a **Parquet export ↔ ClickHouse `s3()` round-trip** (52 rows read back).
- The scripted steps add up to 128 s, including a 20 s pause for ingestion (the longest step, lab 02, took 39 s). Findings worth a blog section came out of the run: the masking proof, RMT dedup, prompt-label movement, a **version drift that the newer image closes** (scheduled Parquet export: rejected on v3.197.1, accepted on v3.225.11), and object-storage archival.

## Environment

| Component | Version / detail |
|---|---|
| Host | Local machine with Docker (OS version not recorded in the run's `env.txt`) |
| Docker Engine | 29.8.2 |
| Docker Compose | v5.5.1 |
| Langfuse (web + worker) | **v3.225.11** (pinned in `_base/v3/versions.env`; `check.sh` reports `Langfuse 3.225.11`) |
| ClickHouse | **26.8.18.2** (`SELECT version()` in lab 11) |
| Postgres / Redis / MinIO | image pins in `_base/docker-compose.yml` (not captured in this run's logs) |
| Masking sidecar | stdlib-only Python callback, `_base/masking/masking_service.py` |
| Python | 3.12.14 (venv `.venv-v3`, `pip install -r _base/v3/requirements.txt`) |
| Python SDK | `langfuse` **3.15.0** (OpenTelemetry-native) |
| Licence | real enterprise licence key for labs 05–11 (value not shown) |
| Run date | 2026-10-06 |

## Run summary

One row per step, from the run's exit codes and timings (`rc` = exit code, `s` = seconds). The run paused 20 s after lab 02 so the worker could finish ingesting before lab 03.

| Step | Feature | rc | s | Result |
|---|---|--:|--:|---|
| Reset | `_base/bin/down.sh v3 --purge` | 0 | 0 | ✅ `Stack v3 down, volumes removed.` |
| 01 up | Stack up (6 containers) | 0 | 21 | ✅ `Langfuse is up after ~15s` |
| 01 check | `_base/bin/check.sh v3` | 0 | 1 | ✅ 11 PASS, 1 SKIP (masking sidecar not started yet); `Langfuse 3.225.11`; migrations applied 37 / shipped 37 |
| 02 | Generate traces (SDK) | 0 | 39 | ✅ 40 traces generated (offline mode) |
| 03 | Explore CH backend | 0 | 0 | ✅ `traces`/`observations`/`scores` = `ReplacingMergeTree`, monthly partitions; 41 raw → 40 deduped traces |
| 04 | Analytics on CH | 0 | 0 | ✅ 8 queries — cost/latency p95/quality/leaderboard |
| 05 | Activate Enterprise | 0 | 12 | ✅ `Enterprise active. Admin API reachable.` |
| 06 | RBAC & SCIM | 0 | 1 | ✅ org + project + 2 SCIM users + project-level role override |
| 07 | Data retention + audit | 0 | 1 | ✅ 14-day retention; audit log shows 6 rows from lab 06/07 |
| 08 | **Server-side data masking** | 0 | 19 | ✅ **leak counts = 0 in ClickHouse; 24 rows carry `[REDACTED_*]`** |
| 08 logs | Sidecar log | 0 | 0 | ✅ `redactions=84` |
| 09 | Prompt labels | 0 | 1 | ✅ v1→v2 label move; prompts in Postgres; 2 audit rows. The protected-label UI step is printed, not exercised |
| 10 | Instance governance | 0 | 11 | ✅ UI + org-creator vars injected & shown in the container env |
| 11 | Parquet export ↔ CH | 0 | 2 | ✅ integration API **accepted** `PARQUET`; CH `s3()` wrote Parquet and read **52** rows back |

---

## Reset — clean slate

```console
$ _base/bin/down.sh v3 --purge

▶ Stopping the v3 stack and DELETING all its data volumes…
✅ Stack v3 down, volumes removed.
```

## Lab 01 — Deploy the stack (OSS)

```console
$ cd labs/v3/langfuse-ee
$ ./01-up.sh

▶ Starting Langfuse v3 stack in OSS mode (postgres · clickhouse · redis · minio · web · worker)…
 …
 Container langfuse-hols-v3-langfuse-web-1 Started
▶ Waiting for langfuse-web to become healthy (first boot runs DB + ClickHouse migrations, ~2-3 min)…
..✅ Langfuse is up after ~15s.

────────────────────────────────────────────────────────────
  Langfuse UI      http://localhost:3000   (track v3)
  Login            admin@example.com / workshop-admin-pw
  Project          LLM Observability
  API public key   pk-lf-workshop-public

  MinIO console    http://localhost:9091   (minio / miniosecret)
  ClickHouse HTTP  http://localhost:8123   (clickhouse / clickhouse)

  Next (from the repository root):
    _base/bin/check.sh v3                  # readiness: containers, migrations, keys
    python3.12 -m venv .venv-v3 && source .venv-v3/bin/activate     # Python 3.10+
    pip install -r _base/v3/requirements.txt
    python _base/v3/seed_traces.py         # or the lab's own seed script
────────────────────────────────────────────────────────────
```

```console
$ _base/bin/check.sh v3

stack: langfuse-hols-v3  (env file: _base/.env)

PASS  container langfuse-web running
PASS  container langfuse-worker running
PASS  container postgres running, healthy
PASS  container clickhouse running, healthy
PASS  container redis running, healthy
PASS  container minio running, healthy
PASS  web http://localhost:3000/api/public/health -> 200 (Langfuse 3.225.11)
PASS  web version 3.225.11 equals LANGFUSE_VERSION (v3 pin or override)
PASS  worker http://localhost:3030/api/health -> 200
PASS  ClickHouse migrations finished (applied 37, shipped 37, dirty 0)
PASS  SDK keys accepted (http://localhost:3000/api/public/projects -> 200)
SKIP  masking sidecar
     not running -- only lab 08 (docker-compose.masking.yml) starts it

1 check(s) skipped -- a skip is not a pass.
stack is ready.
```

The compose file uses **headless initialization** (`LANGFUSE_INIT_*`) to auto-create the first org/project/user/API-keys on boot — no UI click-ops before you can send data. The stack reported healthy after ~15 s, and `check.sh` confirms the running web version equals the pin (3.225.11). The masking sidecar is a deliberate SKIP here: only lab 08 starts it.

## Lab 02 — Generate traces via the Python SDK

```console
$ python3.12 -m venv .venv-v3 && source .venv-v3/bin/activate   # repository root
$ pip install -r _base/v3/requirements.txt
$ cd labs/v3/langfuse-ee
$ python 02-generate-traces.py

✓ Connected. Generating 40 traces (offline / simulated)…
  …10/40 traces
  …20/40 traces
  …30/40 traces
  …40/40 traces
✓ Done. Open http://localhost:3000 → Tracing → Traces.
  Then run the ClickHouse labs:  03-clickhouse-explore.sql, 04-clickhouse-analytics.sql
```

Each trace is a nested observation tree (`support-request` span → `retrieve-context` span → `answer-generation` generation → occasional `self-check`), with per-trace scores. Cost is derived by Langfuse from model name + token usage.

## Lab 03 — Explore the ClickHouse backend

```console
$ docker exec -i langfuse-hols-v3-clickhouse-1 clickhouse-client \
    -u clickhouse --password clickhouse --multiquery < 03-clickhouse-explore.sql
```

Tables Langfuse created (note the `*MergeTree` engines):

```
analytics_observations  View
analytics_scores        View
analytics_traces        View
blob_storage_file_log   ReplacingMergeTree
dataset_run_items       ReplacingMergeTree
dataset_run_items_rmt   ReplacingMergeTree
event_log               MergeTree
observations            ReplacingMergeTree
project_environments    AggregatingMergeTree
schema_migrations       MergeTree
scores                  ReplacingMergeTree
traces                  ReplacingMergeTree
```

Engine / partition / sort key for the three tables that matter:

```
observations  ReplacingMergeTree  toYYYYMM(start_time)  project_id, type, toDate(start_time), id
scores        ReplacingMergeTree  toYYYYMM(timestamp)   project_id, toDate(timestamp), name, id
traces        ReplacingMergeTree  toYYYYMM(timestamp)   project_id, toDate(timestamp), id
```

Row counts, and the **ReplacingMergeTree gotcha** — raw rows can exceed the deduped truth until a merge runs:

```
scores        76
traces        41
observations 130

raw_rows   deduped_active
   41            40          -- FINAL + WHERE is_deleted = 0 gives the truth
```

The duplicate is visible in the five newest `traces` rows: id `7d8242641ba362e7afa415e56d204496` appears twice, once complete and once as a half-populated version (empty name, `\N` user and session, no tags):

```
7d8242641ba362e7afa415e56d204496	support-request	user_008	sess_user_008_7	['env:staging','feature:search-assist','tier:free']	default	2026-10-06 11:07:42.972
7d8242641ba362e7afa415e56d204496		\N	\N	[]	default	2026-10-06 11:07:42.972
```

Selected columns confirm `input`/`output` are `Nullable(String)` (ZSTD(3)-compressed), `usage_details`/`cost_details` are `Map(...)`, and everything carries `event_ts` / `is_deleted` for RMT versioning + soft-deletes.

## Lab 04 — Analytics directly on ClickHouse

```console
$ docker exec -i langfuse-hols-v3-clickhouse-1 clickhouse-client \
    -u clickhouse --password clickhouse --multiquery < 04-clickhouse-analytics.sql
```

**1) Spend & tokens by model** — `sum()` over `Map` columns:

| model | calls | input_tok | output_tok | total_cost_usd | avg_cost/call |
|---|--:|--:|--:|--:|--:|
| claude-3-5-sonnet-20241022 | 10 | 9,311 | 3,292 | 0.077313 | 0.007731 |
| gpt-4o | 15 | 10,795 | 3,171 | 0.058698 | 0.003913 |
| gpt-4o-mini | 25 | 12,456 | 2,827 | 0.003565 | 0.000143 |

**2) Latency p50/p95/p99 per model** — `quantile()` over `dateDiff` (the log prints raw floats such as `1597.1999999999998`; shown here rounded to 2 decimals):

| model | calls | avg_ms | p50 | p95 | p99 |
|---|--:|--:|--:|--:|--:|
| claude-3-5-sonnet-20241022 | 10 | 1,170 | 1,106 | 1,597.20 | 1,627.44 |
| gpt-4o | 15 | 979 | 1,045 | 1,446.90 | 1,515.78 |
| gpt-4o-mini | 25 | 275 | 217 | 559.00 | 562.28 |

**3) Error rate per model** — `countIf(level='ERROR')`:

| model | calls | errors | error_pct |
|---|--:|--:|--:|
| gpt-4o | 15 | 2 | 13.33 |
| claude-3-5-sonnet-20241022 | 10 | 1 | 10.00 |
| gpt-4o-mini | 25 | 1 | 4.00 |

**4) Cost & quality by customer tier** — `arrayFirst()` over `tags` + JOIN:

| tier | traces | cost_usd | cost_per_trace |
|---|--:|--:|--:|
| enterprise | 13 | 0.050497 | 0.003884 |
| free | 14 | 0.047938 | 0.003424 |
| pro | 13 | 0.04114 | 0.003165 |

**5) Satisfaction from scores** — `sumIf`/`avgIf`: thumbs votes **40**, thumbs-up **75%**, avg grounding **0.788**.

**6) Per-user spend leaderboard** (top rows): `user_005` 4 sessions / 4 req / $0.030281 · `user_003` 5 / 6 / $0.02222 · `user_008` 4 / 4 / $0.015265 …

**7) Daily trend**: `2026-10-06` → 40 traces, 12 unique users, $0.139575.

**8) Session depth**: 26 sessions with 1 turn, 7 sessions with 2 turns.

---

## Lab 05 — Activate Enterprise

```console
$ ./05-ee-activate.sh

▶ Re-deploying with the Enterprise overlay (license key + admin API)…
 …
▶ Verifying Enterprise activation via the Instance Management API…
✅ Enterprise active. Admin API reachable. Current organizations:
{"organizations":[{"id":"ch-workshop","name":"ClickHouse Workshop","createdAt":"2026-10-06T11:06:58.765Z","metadata":{},"projects":[{"id":"llm-observability","name":"LLM Observability", …}]}]}
```

The overlay injects `LANGFUSE_EE_LICENSE_KEY` into **both** containers plus `ADMIN_API_KEY` (values not shown). Proof of activation: `/api/admin/organizations` only answers HTTP 200 when a valid license is present — the script prints the success line only on a 200.

## Lab 06 — RBAC & SCIM (full self-service admin chain)

```console
$ ./06-ee-rbac-scim.sh

════ 1. Create an organization (Instance Management API, Bearer auth) ════
  org id = cmuwks1mf0002ta07f7bge5ut
════ 2. Mint an organization-scoped API key ════
  org public key = pk-lf-0b592c60-…            (secret not printed)
════ 3. Create a project under the org ════
  project id = cmuwks1sx0008ta079nqf5d1p
════ 4. Mint a project API key (this is what an app would use to send traces) ════
  project public key = pk-lf-a18c8b87-…
════ 5. SCIM: provision two users (as an IdP like Okta/Entra would) ════
  alice id = cmuwks1y1…   bob id = cmuwks1yv…
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

The finale is the EE feature: **Bob is `VIEWER` org-wide but `ADMIN` on one project** — fine-grained per-project RBAC, all provisioned via API (no UI clicks), exactly how an IdP / Terraform / CI pipeline would do it.

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
       created_at        | action | resource_type |        resource_id        |          org_id           |           actor           
-------------------------+--------+---------------+---------------------------+---------------------------+---------------------------
 2026-10-06 11:08:19.751 | create | apiKey        | cmuwks2hw000pta07c36lqga4 | ch-workshop               | ADMIN_KEY
 2026-10-06 11:08:19.066 | create | orgMembership | cmuwks1yw000ita07b7nhupcw | cmuwks1mf0002ta07f7bge5ut | cmuwks1re0005ta071ub0fwbf
 2026-10-06 11:08:19.037 | create | orgMembership | cmuwks1y3000eta079pnyzm7n | cmuwks1mf0002ta07f7bge5ut | cmuwks1re0005ta071ub0fwbf
 2026-10-06 11:08:18.989 | create | apiKey        | cmuwks1wq000ata07q5o4wejy | cmuwks1mf0002ta07f7bge5ut | ORG_KEY
 2026-10-06 11:08:18.797 | create | apiKey        | cmuwks1re0005ta071ub0fwbf | cmuwks1mf0002ta07f7bge5ut | ADMIN_KEY
 2026-10-06 11:08:18.626 | create | organization  | cmuwks1mf0002ta07f7bge5ut | cmuwks1mf0002ta07f7bge5ut | ADMIN_KEY
(6 rows)
```

The script reports that a nightly job deletes traces/observations/scores older than the window straight from ClickHouse (minimum window 3 days; `0` keeps data forever). That deletion is **not observed in this run** — only the policy write (`retentionDays: 14`) is; and the earlier claim that a non-zero value is rejected on OSS was not re-run on 2026-10-06 (this run was Enterprise-only for lab 07). The audit log is the who/what/when: the six most recent rows are lab 06's organization create, its API-key creates and its two `orgMembership` creates (all in org `cmuwks1mf0002ta07f7bge5ut`), plus one more `apiKey` create in org `ch-workshop` (consistent with lab 07's own org-key mint). The table has `before` / `after` columns for the state change.

---

## Lab 08 — Server-Side Data Masking ⭐ (proven in ClickHouse)

The flagship demo: a tiny stdlib masking-callback sidecar is wired to the worker; Langfuse POSTs each OTLP-ingested trace to it, and it redacts secrets **before** the trace is persisted. We then prove — *with SQL against ClickHouse* — that the raw secrets never landed. (The v3 script prints the leak counts and the masked-row sections; it has no single verdict row and no `--selftest`.)

```console
$ ./08-ee-data-masking.sh

▶ Bringing up the masking sidecar + wiring the worker to it…
 …
 Container langfuse-hols-v3-masking-1 Healthy
▶ Waiting for langfuse-web…
 ready.
▶ Sending PII-laden traces (secrets embedded in input/output/metadata)…
  (using interpreter: python3)
✓ Connected. Sending 12 PII-laden traces to the OTLP endpoint…
▶ Letting the worker ingest + mask (async)…
▶ Verifying against ClickHouse — raw secrets should be GONE, [REDACTED_*] present:
pii-demo traces present	12
── observations: raw-secret leak counts (want all 0) ──
0	0	0	0
── traces: raw-secret leak counts (want all 0) ──
0	0	0	0
── rows carrying a [REDACTED_*] placeholder (want > 0) ──
24
── sample masked observation payloads ──
Row 1:
──────
name:          answer-generation
input_sample:  […, {"role": "user", "content": "Verify my identity, my resident number is [REDACTED_KR_RRN]."}]
output_sample: Thanks, I confirmed the resident number [REDACTED_KR_RRN] on file.

Row 2:
──────
name:          answer-generation
input_sample:  […, {"role": "user", "content": "Our integration uses api key [REDACTED_API_KEY]; is it still valid?"}]
output_sample: The key [REDACTED_API_KEY] is active; rotate it if it was shared.

Row 3:
──────
name:          answer-generation
input_sample:  […, {"role": "user", "content": "My card [REDACTED_CC] was charged twice, please refund."}]
output_sample: I've opened a refund for the card ending in the number you sent ([REDACTED_CC]).
```

The sidecar's own log shows the redaction count for the ingested batch:

```console
$ docker logs --tail 60 langfuse-hols-v3-masking-1

masking-callback listening on :3100 (POST /mask, GET /health)
[mask] project=llm-observability redactions=84
```

**Result:** across both `traces` and `observations`, the four raw sentinel secrets (an API key ending `…0xDEADBEEF01`, `4111 1111 1111 1111`, `victim@secret-corp.test`, `900101-1234567`) return **leak count 0**, while **24 rows** carry `[REDACTED_*]` and the 12 `pii-demo` traces are present. Masking happened in-flight; ClickHouse is the source of truth that proves it. (Per the script's notes: scope is the OTLP endpoint `/api/public/otel` = SDK v3+, and `FAIL_CLOSED=true` drops events if the callback errors — the fail-closed path was not triggered in this run.)

## Lab 09 — Protected Prompt Labels

```console
$ ./09-ee-protected-prompts.sh

════ 1. Create v1 of a prompt, labelled 'production' ════   → {version:1, labels:[production,latest]}
════ 2. Create v2 (stricter) and MOVE 'production' to it ════ → {version:2, labels:[production,latest]}
════ 3. Resolve the current production prompt (what an app fetches) ════
  {version:2, prompt:"You are Acme's senior support assistant. Be concise, cite the KB article id, …"}
════ 4. Prompts are OLTP → stored in POSTGRES, not ClickHouse ════
 version |       labels        |       created_at        
---------+---------------------+-------------------------
       1 | {}                  | 2026-10-06 11:08:40.41
       2 | {production,latest} | 2026-10-06 11:08:40.455
(2 rows)

════ 5. Every label change was AUDITED (ties to lab 07) ════
       created_at        | action | resource_type 
-------------------------+--------+---------------
 2026-10-06 11:08:40.473 | create | prompt
 2026-10-06 11:08:40.425 | create | prompt
(2 rows)
```

**Nice real-world detail:** after v2 takes `production`+`latest`, **v1's labels become `{}`** — deployment labels are *unique pointers that move*, not tags you accumulate. Prompts live in **Postgres** (OLTP), reinforcing the two-database model.

**Not run on 2026-10-06:** the EE capstone. The script's step 6 only *prints* the instructions for marking `production` **protected** (UI toggle, Owner/Admin, EE licence) and the roles from lab 06 (Bob `VIEWER` / Alice `MEMBER` cannot repoint or delete it; Owner/Admin can). Neither the toggle nor those role behaviours were exercised.

## Lab 10 — Instance Governance (UI Customization + Org Creators)

```console
$ ./10-ee-instance-governance.sh

▶ Redeploying langfuse-web with the governance overlay…
time="…" level=warning msg="Found orphan containers (langfuse-hols-v3-masking-1) …"
 …
▶ Waiting for langfuse-web…
. ready.
▶ Proving the governance env is injected into the running container:
LANGFUSE_ALLOWED_ORGANIZATION_CREATORS=admin@example.com
LANGFUSE_UI_DOCUMENTATION_HREF=https://clickhouse.com/docs
LANGFUSE_UI_FEEDBACK_HREF=https://github.com/ClickHouse/clickhouse-hols/issues
LANGFUSE_UI_LOGO_DARK_MODE_HREF=https://clickhouse.com/favicon.ico
LANGFUSE_UI_LOGO_LIGHT_MODE_HREF=https://clickhouse.com/favicon.ico
LANGFUSE_UI_SUPPORT_HREF=https://clickhouse.com/support

✅ Governance config active. Verify in the UI (http://localhost:3000):
  …
```

Both controls are env-driven. The script proves injection by `exec`-ing `env` inside the running container; the UI effects (logo, menu links, hidden "New Organization" action) are the script's verification checklist and were **not** checked in a browser. The **orphan-container warning is expected** — lab 10's overlay set doesn't include lab 08's masking sidecar, so recreating `web`/`worker` here (the log shows both `Recreate`) also drops the masking wiring (each feature overlay is independent; combine overlays if you want several active at once).

## Lab 11 — Parquet Export ↔ ClickHouse

```console
$ ./11-ee-parquet-export.sh

════════════ A) Configure a scheduled Parquet export (Langfuse Org API) ════════════
▶ Minting an org-scoped key for 'ch-workshop'…
▶ PUT /api/public/integrations/blob-storage → try Parquet first…
  ✅ Parquet scheduled export configured:
{ "type":"S3_COMPATIBLE", "bucketName":"langfuse", "fileType":"PARQUET",
  "exportFrequency":"hourly", "exportMode":"FULL_HISTORY", "enabled":true }

════════════ B) The ClickHouse primitive, live (INSERT INTO FUNCTION s3 → read back) ════════════
▶ ClickHouse version (Parquet export failures surface reliably on >= 25.11):
26.8.18.2
▶ Writing active traces to Parquet on MinIO…
▶ Reading the Parquet back from MinIO (round-trip proof):
52
▶ Schema ClickHouse inferred from the exported Parquet (first 15 columns):
    ┌─name────────┬─type─────────────────┐
 1. │ id          │ String               │
 2. │ timestamp   │ DateTime64(3, 'UTC') │
 …  │ …           │ …                    │
13. │ input       │ Nullable(String)     │
14. │ output      │ Nullable(String)     │
```

> **Two Langfuse versions, two answers.** On **v3.225.11** (this run, 2026-10-06) the blob-storage integration API **accepts** `fileType: PARQUET` — the script's success branch above. On **v3.197.1** (the 2026-07-26 run, **not re-run**) the same call was **rejected with HTTP 400** (`fileType` allowed only `JSON`, `CSV`, `JSONL`) and the script fell back to a scheduled `JSONL` export.

Part B prints only the **read-back count: 52** rows. The v3 script does not print a separate source count, so this file makes no equality claim between the two. The separate cross-check from the earlier run (live `traces FINAL` count vs Parquet read-back, and a per-object size query) was **not re-run** on 2026-10-06 and its numbers are not carried over. The inferred-schema box is cut off by the script's `head -18`, so it shows no closing border, and its label still says "first 15 columns" although 17 rows print. Both were fixed after this run (#37): the script now prints the source count next to the read-back count, fails on a mismatch, and cuts the schema box to 15 rows with its border. This log is from before the fix.

Part B is the exact primitive Langfuse's scheduled exporter uses under the hood — `INSERT INTO FUNCTION s3(...) … 'Parquet'` then read it right back — so the ClickHouse-backed store can archive itself to object storage and stay queryable by ClickHouse, DuckDB, Athena, Spark… Pairs with lab 07 as **archive-then-delete** (the script prints that pattern; the log does not show the hourly job's output files, so they were not inspected).

---

## Findings & gotchas (blog-worthy)

1. **Masking is provable in the warehouse, not just claimed.** With server-side masking on, a SQL scan of `traces`/`observations` for the raw secrets returns **0** while `[REDACTED_*]` placeholders are present (24 rows; sidecar logged 84 redactions). ClickHouse turns "we mask PII" into a testable assertion. Scope caveat (script notes): masking only applies to the OTLP endpoint (SDK v3+).

2. **ReplacingMergeTree: raw ≠ truth until merged.** Right after ingestion the `traces` table showed **41 raw rows → 40 deduped** (`FINAL` + `WHERE is_deleted = 0`), and the five newest rows even contained one trace id twice (a complete version and a half-populated one). Every analytics query must read this way or it double-counts half-populated row versions. Sort key `project_id, toDate(timestamp), id`; partition `toYYYYMM(timestamp)`.

3. **Deployment labels *move*.** Creating prompt v2 with `production` silently cleared the label from v1 (`labels = {}`). Labels are unique pointers, which is exactly why the EE "protected label" feature exists — to stop an accidental repoint of production. (The protected-label toggle itself was not exercised in this run.)

4. **Check the API surface of the *running* image, not the docs.** The blob-storage *integration* API on **v3.197.1** (2026-07-26 run, not re-run) accepted `fileType` ∈ `{JSON, CSV, JSONL}` only — `PARQUET` returned HTTP 400, even though the published OpenAPI spec listed `PARQUET`. On **v3.225.11** (2026-10-06) the same call is accepted. Meanwhile **ClickHouse writes true Parquet regardless** (Part B). Lesson for self-hosters: pin versions and validate against the running image — the drift was real on one pin and gone on the next.

5. **ClickHouse ≥ 25.11 is the script's stated baseline for Parquet exports.** The lab script says that on older ClickHouse, Langfuse's Parquet blob-storage export can "succeed" (manifest written) while producing an invalid/incomplete file, and that failures surface reliably on ≥ 25.11. That is the script's own comment: this run used only ClickHouse **26.8.18.2** and did not test any older version, so the claim is **not re-measured**. Below that baseline, prefer CSV/JSON/JSONL.

6. **Overlays are independent; expect orphan warnings.** Each feature (masking, governance) is a separate compose overlay. Bringing one up recreates `web`/`worker` with *that* overlay's env only — so running lab 10 printed an orphan-container warning for lab 08's masking sidecar and recreated the worker without it. Combine overlays (`-f … -f …`) to run several features at once.

7. **Interpreter auto-detection in lab 08.** The driver picks its Python itself — `.venv/bin/python` in the lab directory if present, else `python3`, else `python` — and the 2026-10-06 log shows `(using interpreter: python3)`. This was added during the 2026-07-26 run, when the driver (hard-coded `python`) failed because macOS does not provide that name; it was not re-tested against a missing `python3`.

## Reproduce it

```bash
# from the repository root
cp _base/.env.example _base/.env      # set LANGFUSE_EE_LICENSE_KEY + ADMIN_API_KEY for 05–11
python3.12 -m venv .venv-v3 && source .venv-v3/bin/activate
pip install -r _base/v3/requirements.txt
# the v3 track runs offline as long as OPENAI_API_KEY is empty

cd labs/v3/langfuse-ee
./01-up.sh                           # OSS stack
../../../_base/bin/check.sh v3       # readiness: containers, migrations, keys
python 02-generate-traces.py
docker exec -i langfuse-hols-v3-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse --multiquery < 03-clickhouse-explore.sql
docker exec -i langfuse-hols-v3-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse --multiquery < 04-clickhouse-analytics.sql

./05-ee-activate.sh                  # → EE
./06-ee-rbac-scim.sh
./07-ee-audit-retention.sh
./08-ee-data-masking.sh              # ⭐ masking proof in ClickHouse
./09-ee-protected-prompts.sh
./10-ee-instance-governance.sh
./11-ee-parquet-export.sh            # Parquet ↔ ClickHouse round-trip

cd ../../..
_base/bin/down.sh v3 --purge         # tear down + wipe volumes
```

---

## 한국어 블로그 아웃라인 (Korean blog outline)

바로 글로 옮길 수 있도록 정리한 서술 구조입니다.

**제목(안):** "Langfuse를 ClickHouse 위에서 셀프호스팅하기 — 엔터프라이즈 기능까지 직접 돌려본 기록"

1. **왜 이 글인가** — 대부분의 Langfuse 튜토리얼은 "Cloud에 trace 보내기"에서 끝난다. 이 글은 셀프호스팅 + 그 밑을 떠받치는 **ClickHouse 백엔드**를 SA 관점에서 직접 열어본다. (환경표: Langfuse v3.225.11 / ClickHouse 26.8.18.2 / SDK 3.15.0, 2026-10-06 실행)
2. **아키텍처 한 장** — web·worker + Postgres(OLTP: 사용자·조직·프롬프트·감사로그) + **ClickHouse(OLAP: trace·observation·score)** + Redis + MinIO. "trace는 Postgres에 없다, ClickHouse에 있다."
3. **OSS 트랙 (01–04)** — headless init로 클릭 없이 부팅 → SDK로 40 trace → **ClickHouse SQL로 비용/지연 p95/품질 분석**. 여기서 **ReplacingMergeTree 함정**(raw 41 → FINAL 40) 설명. (발견 #2)
4. **Enterprise 트랙 (05–11)** — 라이선스 활성화 → Instance Management API 응답 확인. RBAC/SCIM로 **조직 전체 VIEWER지만 특정 프로젝트만 ADMIN**인 Bob(발견: 프로젝트 단위 RBAC). 데이터 보존 + 감사 로그.
5. **하이라이트: 서버측 데이터 마스킹을 ClickHouse로 *증명*** — PII/시크릿을 심은 trace 전송 → `position()`으로 원문 부재(=0) + `[REDACTED_*]` 존재(24행, 사이드카 redactions=84) 확인. "마스킹한다"를 **검증 가능한 명제**로 바꾸는 게 핵심. (발견 #1)
6. **프롬프트 거버넌스** — `production` 라벨이 v1→v2로 **이동**(v1 labels=`{}`)하는 것을 보고 왜 protected label이 필요한지 연결. protected label UI 토글 자체는 이번 실행에서 하지 않았다. (발견 #3)
7. **데이터 반출: Parquet ↔ ClickHouse 라운드트립** — `INSERT INTO FUNCTION s3(...)` → 되읽기 **52행**(v3 스크립트는 되읽은 행 수만 출력한다). archive-then-delete. 그리고 **버전 드리프트 함정**: 통합 API가 v3.197.1(2026-07-26 실행, 이번에 재실행하지 않음)에서는 `PARQUET`을 거부(400)했고 v3.225.11(2026-10-06 실행)에서는 수락한다 — 공개 OpenAPI 스펙은 실행 이미지보다 앞설 수 있다. + **CH ≥ 25.11** 권장은 스크립트 주석 기준이며 이번에 재검증하지 않았다. (발견 #4, #5)
8. **운영 메모** — 오버레이 독립성/orphan 경고(발견 #6), macOS `python` 이식성(발견 #7).
9. **마무리** — 셀프호스팅 Langfuse는 사실상 실전 ClickHouse 애플리케이션이며, ClickHouse가 있으면 관측성·컴플라이언스(마스킹·보존·반출)를 *데이터로* 증명할 수 있다.

**추천 코드/캡처:** 마스킹 leak=0 SQL, RMT raw vs FINAL, 프롬프트 라벨 이동 테이블, `s3()` 되읽기 52행, 버전별 blob-storage 응답(v3.225.11 수락 — 위 로그, v3.197.1 400 — 이전 실행 기록). (400 응답을 제외하면 모두 위 로그에서 그대로 인용 가능)

---

*Captured on 2026-10-06 by running every script in this directory end-to-end (offline, real enterprise licence key) on Langfuse v3.225.11 / SDK 3.15.0 / ClickHouse 26.8.18.2. The raw per-step logs were kept outside the repository.*
