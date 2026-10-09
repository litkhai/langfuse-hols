# Self-Hosting Langfuse on ClickHouse — Workshop (OSS + Enterprise)

[English](#english) | [한국어](#한국어)

---

## English

> **Langfuse v4 track.** The stack versions are pinned in [`_base/v4/versions.env`](../../../_base/v4/versions.env). For a Langfuse v3 deployment use [`labs/v3/langfuse-ee`](../../v3/langfuse-ee/README.md); v3 gets security patches only until 2027-01-31.

> **Related notes** (Korean): [Langfuse, 그리고 ClickHouse: LLM 옵저버빌리티 데이터 스택 해부](https://clickhouse.litkhai.dev/articles/third-party/langfuse-clickhouse-llm/)

A hands-on, end-to-end workshop for **self-hosting [Langfuse](https://langfuse.com)** — the open-source LLM observability platform — and then looking *under the hood* at the **ClickHouse backend** that powers it.

Langfuse stores all of its OLTP state (users, orgs, projects, prompts, the audit log) in **Postgres**, but every **observation and score** lands in **ClickHouse**. The stack here is pinned to **Langfuse v4**, whose data model is *observations-first*: one wide row per observation in `events_full` / `events_core` (a trace is just its root observation, with user, session, tags and metadata repeated on every row), plus `scores`. That makes Langfuse a real, production-grade ClickHouse application you can stand up in minutes — and a great way to *feel* why ClickHouse is the right OLAP engine for high-volume, append-only LLM telemetry.

The workshop has two tracks:

- **OSS track (labs 01–04)** — deploy the full stack with Docker Compose, push realistic traces with the Python SDK, then query the ClickHouse backend directly with SQL.
- **Enterprise track (labs 05–11)** — activate an **enterprise license key** and exercise the EE-only features: **Instance Management / Org API**, project-level **RBAC**, **SCIM** provisioning, **Audit Logs**, **Data Retention**, **Server-Side Data Masking** (proven against ClickHouse), **Protected Prompt Labels**, **UI Customization**, **Organization-Creators allowlist**, and a **Parquet export ↔ ClickHouse** round-trip.

> This directory is the **`-ee` (Enterprise Edition) edition** of the workshop — the OSS track still runs standalone, but the focus is the enterprise feature surface and how each one lands in (or is proven against) ClickHouse.

### 🎯 Why this lab

Most Langfuse tutorials stop at "send a trace to Langfuse Cloud." This one is for **Solution Architects and platform teams** who need to answer:

1. *What does a self-hosted Langfuse deployment actually consist of?* (6 containers, 4 stateful backends)
2. *Where does my LLM telemetry physically live, and can I query it?* (Yes — it's ClickHouse, and lab 04 runs cost/latency/quality analytics straight on it)
3. *What do I get when I add an enterprise license?* (RBAC, SCIM, audit, retention — fully scripted, no UI click-ops)

### 🏗️ Architecture

```
                       ┌─────────────────┐
   your LLM app  ──────►   langfuse-web   │  :3000  UI + Public API
   (SDK / OTEL)        │   langfuse-worker│  :3030  async ingestion + jobs
                       └───────┬─────────┘
            ┌──────────────────┼───────────────────┬───────────────┐
            ▼                  ▼                   ▼               ▼
      ┌──────────┐      ┌────────────┐       ┌─────────┐     ┌──────────┐
      │ Postgres │      │ ClickHouse │       │  Redis  │     │  MinIO   │
      │  OLTP    │      │   OLAP     │       │ queue + │     │  S3 blob │
      │ users,   │      │ events_full│       │  cache  │     │ raw events│
      │ orgs,    │      │ events_core│       └─────────┘     │ media,    │
      │ audit_log│      │ scores     │ ◄── labs 03 & 04      │ exports   │
      └──────────┘      └────────────┘                      └──────────┘
```

### 📁 File Structure

```
langfuse-ee/
├── README.md                    # This file
├── 01-up.sh                     # Wrapper → _base/bin/up.sh v4: stack up, wait for health, print credentials
├── 02-generate-traces.py        # Wrapper → _base/v4/seed_traces.py: nested spans/generations, sessions, scores
├── 03-clickhouse-explore.sql    # Discover the events_full/events_core/scores tables in ClickHouse
├── 04-clickhouse-analytics.sql  # Cost / latency / quality analytics straight on ClickHouse
├── 05-ee-activate.sh            # Restart with the license key, verify EE is active
├── 06-ee-rbac-scim.sh           # Org/project provisioning, SCIM users, project-level RBAC
├── 07-ee-audit-retention.sh     # Data-retention policy + read the audit log
├── 08-ee-data-masking.sh        # Server-side masking, PROVEN absent in ClickHouse
│   ├── 08-generate-pii-traces.py#   ↳ send traces containing sentinel secrets/PII
│   └── 08-verify-masking.sql    #   ↳ ClickHouse proof in events_full: raw secrets gone, [REDACTED_*] present, a PASS/FAIL verdict row
├── 09-ee-protected-prompts.sh   # Versioned prompts + deployment labels + protected labels
├── 10-ee-instance-governance.sh # UI customization + organization-creators allowlist
├── 11-ee-parquet-export.sh      # Blob-storage Parquet export + ClickHouse s3() round-trip
└── 99-cleanup.sh                # Wrapper → _base/bin/down.sh v4: tear the stack down (--purge to wipe volumes)
```

The stack itself is **shared with the other labs** and lives in [`_base/`](../../../_base/README.md) — compose file, EE / masking / governance overlays, the masking sidecar, `.env.example`, and `bin/up.sh` · `bin/check.sh` · `bin/down.sh`:

```
_base/
├── .env.example                 # Secrets, headless-init, EE license key, SDK keys (copy to _base/.env)
├── v3/ · v4/                    # Per track: versions.env (image pins) · requirements.txt (v4: langfuse, anthropic, opentelemetry-instrumentation-anthropic) · seed_traces.py
├── docker-compose.yml           # OSS stack (pinned images): web · worker · postgres · clickhouse · redis · minio
├── docker-compose.ee.yml        # EE overlay: injects license key + admin API key
├── docker-compose.masking.yml   # Lab 08 overlay: masking sidecar + worker callback wiring
├── docker-compose.governance.yml# Lab 10 overlay: UI customization + org-creators allowlist
├── masking/masking_service.py   # Lab 08: tiny stdlib masking-callback sidecar
└── bin/                         # up.sh · check.sh · down.sh (first argument: the track, v3 or v4)
```

### ✅ Prerequisites

- **Docker + Docker Compose** (Docker Desktop on Mac/Windows). Give it ≥ 4 CPU / 16 GiB.
- **Python 3.10+** for lab 02 and the SDK scripts (Langfuse Python SDK v4 requires it; on macOS the system `python3` is older — use e.g. `python3.12`). Install the pinned packages with `pip install -r _base/v4/requirements.txt`.
- *(optional)* an **Anthropic API key** (`ANTHROPIC_API_KEY` in `_base/.env`) to make lab 02 and the eval lab call a real model (`claude-haiku-4-5`) instead of the offline simulation.
- **`jq`** and **`curl`** for the enterprise scripts (05–07).
- An **enterprise license key** for labs 05–07 (the OSS track needs nothing extra).

### 🚀 Quick Start (OSS track)

```bash
# from the repository root
cp _base/.env.example _base/.env   # edit the # CHANGEME secrets for anything non-local
cd labs/v4/langfuse-ee

# 1) Deploy. First boot runs Postgres + ClickHouse migrations (~2-3 min).
./01-up.sh
#    → http://localhost:3000  (login: admin@example.com / workshop-admin-pw)
../../../_base/bin/check.sh v4     # optional: containers healthy, migrations finished, SDK keys valid

# 2) Push ~40 realistic traces (runs fully offline; an Anthropic key is optional)
python3.12 -m venv ../../../.venv-v4 && source ../../../.venv-v4/bin/activate    # Python 3.10+
pip install -r ../../../_base/v4/requirements.txt
python 02-generate-traces.py

# 3) Explore Langfuse's ClickHouse backend
docker exec -i langfuse-hols-v4-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse \
  --multiquery < 03-clickhouse-explore.sql

# 4) Run LLM-observability analytics directly on ClickHouse
docker exec -i langfuse-hols-v4-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse \
  --multiquery < 04-clickhouse-analytics.sql
```

> The container name is fixed by the compose project name (`langfuse-hols-v4`: `langfuse-hols-` plus the track, set in `_base/docker-compose.yml`), so it no longer depends on the directory the stack was started from.

### 🏢 Enterprise Track

```bash
# Put your key in _base/.env:   LANGFUSE_EE_LICENSE_KEY=<your-key>
#                               ADMIN_API_KEY=<any-strong-random-string>

./05-ee-activate.sh          # redeploy with the EE overlay; verify license is active
./06-ee-rbac-scim.sh         # create org → org key → project → SCIM users → RBAC roles
./07-ee-audit-retention.sh   # set a 14-day retention policy + dump the audit log
./08-ee-data-masking.sh      # mask secrets on ingestion; PROVE they never reach ClickHouse
./09-ee-protected-prompts.sh # versioned prompts + deployment labels + protected labels
./10-ee-instance-governance.sh # UI customization + organization-creators allowlist
./11-ee-parquet-export.sh    # Parquet export to object storage + ClickHouse s3() round-trip
```

### 🧩 EE feature coverage

Every Enterprise entitlement listed on the [Langfuse license-key page](https://langfuse.com/self-hosting/license-key), mapped to the lab that exercises it:

| Enterprise entitlement | Lab | ClickHouse angle |
|---|---|---|
| Instance Management API | 05 | — |
| Org Management API & SCIM | 06 | — |
| Project-level RBAC roles | 06 | — |
| Audit Logs | 07 | (audit log is in Postgres) |
| Data Retention policies | 07 | nightly worker deletes old rows from ClickHouse |
| **Server-Side Data Masking** | 08 | **proof runs on ClickHouse** — raw secrets never persist |
| **Protected Prompt Labels** | 09 | (prompts are in Postgres) |
| **UI Customization** | 10 | — |
| **Organization Creators** | 10 | — |
| Parquet Blob-Storage Export* | 11 | **ClickHouse `s3()` writes + re-reads the Parquet** |

\* Scheduled blob-storage export is available to all self-hosted projects (not license-gated), but it's the enterprise data-platform / archival story and the most ClickHouse-native lab — so it lives on the enterprise track.

### 📖 Lab Walkthrough

#### 01 — Deploy the stack ([01-up.sh](01-up.sh))

Brings up the six containers from [docker-compose.yml](../../../_base/docker-compose.yml) (via the shared [`_base/bin/up.sh`](../../../_base/bin/up.sh)) and blocks until `GET /api/public/health` returns OK. The compose file uses **headless initialization** (`LANGFUSE_INIT_*` in `_base/.env`) to auto-create the first organization, project, user, and API keys on boot — so there are **no UI click-ops** before you can send data. Key things to notice: ClickHouse runs single-node (`CLICKHOUSE_CLUSTER_ENABLED=false`), all backends run in **UTC** (a hard Langfuse requirement), and MinIO provides S3-compatible blob storage.

#### 02 — Generate traces ([02-generate-traces.py](02-generate-traces.py))

Uses the **Langfuse Python SDK (v4, OpenTelemetry-native)** to simulate a customer-support RAG assistant. Each trace is a nested observation tree:

```python
with lf.start_as_current_observation(as_type="span", name="support-request",
                                     input={"question": ...}) as root:
    with propagate_attributes(trace_name="support-request", user_id=..., session_id=...,
                              tags=[...], metadata={"tier": ...}):          # on EVERY observation below
        with lf.start_as_current_observation(as_type="span", name="retrieve-context"): ...
        with lf.start_as_current_observation(as_type="generation",
                                             name="answer-generation", model="gpt-4o") as gen:
            gen.update(output=..., usage_details={"input": ..., "output": ...})
    root.update(output=...)
lf.create_score(name="user-thumbs", value=1, data_type="BOOLEAN", trace_id=...)
lf.flush()   # critical in short scripts — sends the async buffer before exit
```

SDK v4 replaced `update_current_trace()` with `propagate_attributes()`: the trace attributes are written onto every observation created inside the block (metadata is `dict[str, str]`, values ≤ 200 characters), and the trace input/output go on the root observation. It varies model, user, session, tags (`env`/`feature`/`tier`), token usage, latency, errors (~8%), and attaches scores. Cost is computed **automatically** by Langfuse from the model name + token usage — but only when the usage keys match the model's price keys, so the generator sends `input` / `output`, and only simulates models that have a price definition (`gpt-4o-mini`, `gpt-4o`, `claude-haiku-4-5`). Runs offline by default; set `ANTHROPIC_API_KEY` in `_base/.env` to make real calls with the official `anthropic` SDK, traced by `opentelemetry-instrumentation-anthropic` (the call shows up as a `GENERATION` with the model, tokens and cost).

#### 03 — Explore the ClickHouse backend ([03-clickhouse-explore.sql](03-clickhouse-explore.sql))

Pure discovery against the `default` database Langfuse migrated into: `SHOW TABLES`, `DESCRIBE events_full/events_core/scores`, engine + sort-key + partitioning, row counts, the full observation tree for one trace, and the monthly partition layout. **There is no trace row any more: a trace is the root row (`is_app_root`) of `events_full` / `events_core`, its steps are the other rows with the same `trace_id`, and scores live in `scores`.** The v3 tables `traces` and `observations` still exist but stay empty — the lab prints their row counts (0) as the evidence that v4 writes elsewhere.

> The ClickHouse schema is an internal Langfuse detail, **not a stable API** — v3 → v4 moved everything from `traces` / `observations` to `events_full` / `events_core`, and column names can change again. The `DESCRIBE` output is always the source of truth for your installed version.

#### 04 — Analytics on ClickHouse ([04-clickhouse-analytics.sql](04-clickhouse-analytics.sql))

The SA payoff: the same questions the Langfuse UI answers, expressed as plain ClickHouse SQL — and a showcase of why ClickHouse fits this workload.

| Query | ClickHouse primitive |
|---|---|
| Spend & tokens by model | `sum()` over `total_cost` and the `usage_details` `Map`, on `type = 'GENERATION'` rows |
| Latency p50/p95/p99 per model | `quantile()` over `dateDiff('millisecond', start_time, end_time)` |
| Error rate per model | `countIf(level = 'ERROR')` conditional aggregation |
| Cost by customer tier | `metadata_values[indexOf(metadata_names, 'tier')]` — metadata is two parallel arrays; **no join** |
| Quality by customer tier | the one remaining join: `scores.trace_id = events_core.trace_id` |
| Thumbs-up rate / grounding | `sumIf`/`avgIf` over the `scores` table |
| Per-user spend leaderboard | one pass over `events_core` — `user_id` is on every row |
| Daily trend / session depth | time bucketing + `uniqExactIf` / `countIf(is_app_root)` |

The v4 lesson of this lab: the v3 queries joined `traces` to `observations` to learn the user or the tier of a generation. In v4 every observation row already carries them, so those joins disappear.

#### 05 — Activate Enterprise ([05-ee-activate.sh](05-ee-activate.sh))

Redeploys `langfuse-web` + `langfuse-worker` with [docker-compose.ee.yml](../../../_base/docker-compose.ee.yml), which injects `LANGFUSE_EE_LICENSE_KEY` into **both** containers (plus `ADMIN_API_KEY`). It verifies activation by hitting the **Instance Management API** (`/api/admin/organizations`) — which only responds when a valid license is present.

#### 06 — RBAC & SCIM ([06-ee-rbac-scim.sh](06-ee-rbac-scim.sh))

The complete self-service admin chain, fully scripted:

```
ADMIN_API_KEY → create Organization → mint org-scoped API key
     org key   → create Project → mint project API key
     org key   → SCIM: provision users → assign ORG roles
     org key   → assign a PROJECT-level role that overrides the org role  (EE)
```

Roles: `OWNER` (all) · `ADMIN` (settings + members) · `MEMBER` (view + create scores) · `VIEWER` (read-only). The finale gives Bob `VIEWER` org-wide but `ADMIN` on one project — **per-project RBAC is an enterprise feature**.

#### 07 — Audit Logs & Data Retention ([07-ee-audit-retention.sh](07-ee-audit-retention.sh))

- **Data Retention**: sets a 14-day retention on the project via `PUT /api/public/projects/{id}`. A non-zero value requires the data-retention entitlement (EE) — the same call is rejected on OSS. A nightly worker then deletes traces/observations/scores older than the window straight from ClickHouse.
- **Audit Logs**: discovers the audit table in Postgres and dumps the most recent who/what/when records — including the org/project/membership changes lab 06 just made, with full before/after state.

#### 08 — Server-Side Data Masking ([08-ee-data-masking.sh](08-ee-data-masking.sh))

The flagship **ClickHouse-verifiable** EE demo. A tiny masking-callback sidecar ([masking_service.py](../../../_base/masking/masking_service.py), stdlib only) is wired to the worker via [docker-compose.masking.yml](../../../_base/docker-compose.masking.yml) as `LANGFUSE_INGESTION_MASKING_CALLBACK_URL`. Langfuse POSTs each OTLP-ingested trace to it; the service redacts anything matching a secret/PII pattern (API keys, credit cards, e-mails, KR 주민등록번호) and returns the same structure — **before** the trace is persisted.

[08-generate-pii-traces.py](08-generate-pii-traces.py) sends traces containing four sentinel secrets (in the input, the output and the metadata), then [08-verify-masking.sql](08-verify-masking.sql) proves the payoff **directly on ClickHouse**, in `events_full` — the table with the full, untruncated payloads:

```sql
-- want ALL ZERO: no raw secret reached the OLAP store (input, output or metadata)
countIf(position(input, '0xDEADBEEF01') > 0 OR position(output, '0xDEADBEEF01') > 0
     OR arrayExists(v -> position(v, '0xDEADBEEF01') > 0, metadata_values))  AS leaked_api_key
-- want > 0: the redaction placeholders did land
countIf(position(input, '[REDACTED_') > 0 OR position(output, '[REDACTED_') > 0)  AS masked_payload_rows
```

The file ends with one explicit **`verdict`** row — `PASS` only if the pii-demo rows landed **and** some of them carry a `[REDACTED_*]` placeholder **and** every leak count is `0`, otherwise `FAIL` — and `08-ee-data-masking.sh` exits `1` on `FAIL`. A "0 leaks" result proves nothing if the table is empty, so `./08-ee-data-masking.sh --selftest` is the positive control: it points the same SQL at an empty copy of `events_full` and requires the verdict to be `FAIL`.

Key facts: masking applies **only** to the OTLP endpoint (`/api/public/otel` = SDK v3+); `FAIL_CLOSED=true` drops events if the callback errors (secure default); the callback body is an **OTLP Trace Request proto in JSON**, so the sidecar deep-walks the JSON and only rewrites string leaves.

#### 09 — Protected Prompt Labels ([09-ee-protected-prompts.sh](09-ee-protected-prompts.sh))

Prompt governance. The script creates a versioned prompt, moves the `production` label from v1 → v2 via the API, resolves the current production prompt, then shows those versions living in **Postgres** (prompts are OLTP — not ClickHouse) and the matching rows in the **audit log** (ties back to lab 07). The capstone is the EE **protected label**: once `production` is marked protected in Project Settings, the lab-06 roles apply — Bob (`VIEWER`) and Alice (`MEMBER`) can no longer repoint or delete it, only Owner/Admin can. Protection is toggled in the UI (no public API); enforcement is per user role.

#### 10 — Instance Governance ([10-ee-instance-governance.sh](10-ee-instance-governance.sh))

Two instance-level controls, both env-driven via [docker-compose.governance.yml](../../../_base/docker-compose.governance.yml): **UI Customization** (`LANGFUSE_UI_LOGO_*`, `LANGFUSE_UI_FEEDBACK/DOCUMENTATION/SUPPORT_HREF` — co-brand + point help links inward) and the **Organization-Creators allowlist** (`LANGFUSE_ALLOWED_ORGANIZATION_CREATORS` — only listed emails may create new orgs). The script redeploys `langfuse-web`, then `exec … env | grep`s the running container to **prove the vars are live**, and prints a UI verification checklist.

#### 11 — Parquet Export ↔ ClickHouse ([11-ee-parquet-export.sh](11-ee-parquet-export.sh))

The enterprise data-platform / archival story, in two parts. **(A)** Configure a scheduled **Parquet** blob-storage export via `PUT /api/public/integrations/blob-storage` (type `S3_COMPATIBLE`, pointed at the workshop MinIO). On v4 the integration's `exportSource` must be the enriched observations source, `OBSERVATIONS_V2`; the legacy `LEGACY_TRACES_OBSERVATIONS` source reads the v3 tables, and Langfuse's export docs state that legacy sources are unavailable in the default `events_only` mode. **(B)** Demonstrate the exact primitive that powers it, **live**, with ClickHouse — no waiting on the scheduler:

```sql
INSERT INTO FUNCTION s3('http://minio:9000/langfuse/exports/manual/events_full.parquet',
                        'minio', 'miniosecret', 'Parquet')
  SELECT * FROM default.events_full FINAL WHERE is_deleted = 0 SETTINGS s3_truncate_on_insert = 1;
SELECT count() FROM s3('http://minio:9000/langfuse/exports/manual/events_full.parquet',
                       'minio', 'miniosecret', 'Parquet');   -- read it right back
```

The script prints the source and Parquet row counts side by side and exits `1` if they differ.

Pairs with lab 07 as **archive-then-delete**: export before retention deletes. SA gotcha baked in — on self-hosted, **ClickHouse < 25.11** may not surface Parquet export failures (a run can "succeed" with an invalid file); upgrade to ≥ 25.11 or use CSV/JSON for reliable failure detection.

### 🔑 Gotchas worth remembering

| | Note |
|---|---|
| **Two databases, two jobs** | Postgres = OLTP (users, orgs, prompts, **audit log**). ClickHouse = OLAP (**events_full / events_core, scores**). Don't look for traces in Postgres — and on v4 not in the `traces` table either. |
| **UTC everywhere** | ClickHouse **and** Postgres must run in UTC, or queries return wrong/empty results. The compose file sets this. |
| **`flush()` in scripts** | The SDK ships data asynchronously. A short script that exits without `lf.flush()` loses its traces. |
| **Cost is derived** | You send `usage_details` (tokens); Langfuse computes cost from its model price table — but only when the usage keys match the model's price keys. Send `input` / `output`, and use model names it has a definition for (`gpt-4o`, `claude-haiku-4-5`). |
| **Trace attributes are per observation** | SDK v4 has no `update_current_trace()`. Wrap the work in `propagate_attributes(...)`; metadata is `dict[str, str]`, values ≤ 200 characters. |
| **Don't seed the global RNG** | `random.seed()` makes OpenTelemetry reuse the same trace and span ids on every run, and the duplicate rows survive `FINAL`. The generators use a private `random.Random`. |
| **EE license on BOTH containers** | `LANGFUSE_EE_LICENSE_KEY` must be set on `langfuse-web` *and* `langfuse-worker`. The overlay does this. |
| **CH schema ≠ API** | Query ClickHouse directly for labs/debugging, but treat the schema as unstable. For apps, use the Public API / SDK query helpers / Blob Storage Export. |
| **`retention=0` = forever** | Minimum non-zero retention is 3 days. Pair retention with a Blob Storage Export if you must archive before deletion. |

### 📝 Verification status

Verified **end-to-end on 2026-10-10** against **Langfuse v4.56.0 / SDK 4.17.0 / ClickHouse 26.8.22.13** (track v4, [#55](https://github.com/litkhai/langfuse-hols/issues/55)).

- **Stack:** the pinned stack in [`_base/`](../../../_base/README.md) (`_base/v4/versions.env`): Docker 29.8.2, Compose v5.5.1, Python 3.12.14, fresh volumes, default `events_only` write mode.
- **EE:** a real enterprise license key.
- **Model calls:** labs 01–11 ran offline. Lab 02 was also run with real Anthropic calls (`claude-haiku-4-5`).

The full captured console output of the 01 → 11 run is in **[lab-output.md](lab-output.md)** (blog-ready).

| Step | Result |
|---|---|
| `01` stack up | 6 containers; `/api/public/health` → version `4.56.0`; `_base/bin/check.sh v4` all PASS, including the health version equal to the pin and ClickHouse migrations applied 51 / shipped 51 |
| `02` generate traces | 40 traces offline + 5 with real `claude-haiku-4-5` calls (traced by OpenTelemetry, priced by Langfuse at $0.001303 for the 5) |
| `03` explore | data in `events_full` / `events_core` (158 rows each) and `scores` (88); the v3 `traces` / `observations` tables exist and hold **0** rows |
| `04` analytics | all 8 queries return rows from `events_core`; per-model cost non-zero for every model, the real `claude-haiku-4-5-20251001` calls included; no joins needed |
| `05` EE activate | Instance Management API `/api/admin/organizations` → HTTP 200 (license valid) |
| `06` RBAC/SCIM | org + project + 2 SCIM users + project-level role override, all via API |
| `07` audit/retention | 14-day retention set (`retentionDays: 14`); the audit log holds 9 rows: the lab-06 organization, its 2 org memberships and 2 updates to them, the project membership of the role override, 2 API keys of that organization, and an API key in the `ch-workshop` organization created with the admin key (project creation and the SCIM users are not among them). On 4.53.0 it held 6, without the membership updates and the project membership |
| `08` data masking | verdict **PASS**: 24 pii-demo rows masked, leak counts `0` across input / output / metadata in `events_full`; sidecar logged **108 redactions**. `--selftest`: the verdict FAILs on an empty table |
| `09` protected prompts | v1→v2 label move (v1 `labels={}`, v2 `{production,latest}`); prompt rows in Postgres; 2 `create prompt` audit rows |
| `10` governance | all `LANGFUSE_UI_*` + `LANGFUSE_ALLOWED_ORGANIZATION_CREATORS` confirmed in the container env |
| `11` parquet export | the integration API **accepts `fileType: PARQUET`** with the `OBSERVATIONS_V2` export source; CH `s3()` round-trip **182 == 182**. The hourly job had not fired before teardown, so its files are not proven |

> **Version drift (lab 11), resolved by the pin.** On v3.197.1 the integration API rejected `fileType: PARQUET` with HTTP 400 (`JSON` / `CSV` / `JSONL` only), although the published OpenAPI spec listed it. v4.48.0 accepted it, and so does the pinned **v4.56.0** (2026-10-10). The lab script still tries `PARQUET` first and falls back to `JSONL`, so it also works against an older image. Validate the API surface against your *running* image, not just the docs.

Confirmed at runtime and built into the labs:

1. **v4 writes observations to `events_full` / `events_core`.** The old tables stay empty, so the analytics read `events_core FINAL` and the masking proof reads `events_full` (full payloads) with `FINAL` + `WHERE is_deleted = 0`.
2. **Cost is computed only for usage keys the model's price definition has.** Measured on v4.48.0, `gpt-4o-mini` with `input_tokens` / `output_tokens` gets `total_cost = 0`, while `input` / `output` is priced. The generator therefore sends `input` / `output`.

The ClickHouse `DESCRIBE` output in lab 03 is authoritative for your installed version.

### 🔍 Additional resources

- [Self-host Langfuse — overview](https://langfuse.com/self-hosting)
- [Docker Compose deployment](https://langfuse.com/self-hosting/deployment/docker-compose)
- [ClickHouse for Langfuse](https://langfuse.com/self-hosting/deployment/infrastructure/clickhouse)
- [Enterprise License Key](https://langfuse.com/self-hosting/license-key)
- [Access Control (RBAC)](https://langfuse.com/docs/administration/rbac) · [SCIM & Org API](https://langfuse.com/docs/administration/scim-and-org-api)
- [Audit Logs](https://langfuse.com/docs/administration/audit-logs) · [Data Retention](https://langfuse.com/docs/administration/data-retention)
- [Server-Side Data Masking](https://langfuse.com/self-hosting/security/data-masking) · [Protected Prompt Labels](https://langfuse.com/docs/prompt-management/features/prompt-version-control)
- [UI Customization](https://langfuse.com/self-hosting/administration/ui-customization) · [Organization Creators](https://langfuse.com/self-hosting/administration/organization-creators)
- [Export to Blob Storage](https://langfuse.com/docs/api-and-data-platform/features/export-to-blob-storage) · [ClickHouse `s3` table function](https://clickhouse.com/docs/sql-reference/table-functions/s3)
- [Python SDK](https://langfuse.com/docs/observability/sdk/overview) · [Python SDK v3 → v4](https://langfuse.com/docs/observability/sdk/upgrade-path/python-v3-to-v4) · [Server v3 → v4](https://langfuse.com/self-hosting/upgrade/upgrade-guides/upgrade-v3-to-v4)
- [Anthropic integration (OpenTelemetry)](https://langfuse.com/integrations/model-providers/anthropic)

### 📝 License

[MIT](../../../LICENSE) — same as the rest of the repository.

### 👤 Author

Ken Lee (ClickHouse Solution Architect) — ken.lee@clickhouse.com
Created: 2026-06-25 · EE track (labs 08–11) added: 2026-07-26

---

**Happy Tracing! 🔭**

For questions, see the main [langfuse-hols README](../../../README.md).

---

## 한국어

> **Langfuse v4 트랙.** 스택 버전은 [`_base/v4/versions.env`](../../../_base/v4/versions.env)에 고정되어 있습니다. Langfuse v3를 운영 중이라면 [`labs/v3/langfuse-ee`](../../v3/langfuse-ee/README.md)를 쓰세요. v3 보안 패치는 2027-01-31까지만 나옵니다.

> **관련 글**: [Langfuse, 그리고 ClickHouse: LLM 옵저버빌리티 데이터 스택 해부](https://clickhouse.litkhai.dev/articles/third-party/langfuse-clickhouse-llm/)

**[Langfuse](https://langfuse.com) self-hosting** — 오픈소스 LLM 관측가능성(observability) 플랫폼 — 을 직접 구축하고, 그 내부를 떠받치는 **ClickHouse 백엔드**까지 들여다보는 종단간 실습입니다.

Langfuse는 OLTP 상태(사용자·조직·프로젝트·프롬프트·감사 로그)를 **Postgres**에 저장하지만, 모든 **observation과 score**는 **ClickHouse**에 적재됩니다. 이 스택은 **Langfuse v4**로 고정되어 있으며, v4의 데이터 모델은 *observation 우선*입니다. observation 하나가 `events_full` / `events_core`의 넓은 행 하나이고(trace는 곧 루트 observation이며 user·session·tags·metadata가 모든 행에 반복 저장됨), score는 `scores`에 저장됩니다. 즉 Langfuse는 몇 분 만에 띄울 수 있는 실전급 ClickHouse 애플리케이션이며, 고볼륨 append-only LLM 텔레메트리에 왜 ClickHouse가 적합한지를 직접 체감하기에 좋은 사례입니다.

실습은 두 트랙으로 구성됩니다.

- **OSS 트랙 (랩 01–04)** — Docker Compose로 전체 스택 배포 → Python SDK로 현실적인 trace 적재 → ClickHouse 백엔드를 SQL로 직접 조회.
- **Enterprise 트랙 (랩 05–11)** — **엔터프라이즈 라이선스 키**를 활성화하고 EE 전용 기능을 실습: **Instance Management / Org API**, 프로젝트 단위 **RBAC**, **SCIM** 프로비저닝, **감사 로그(Audit Logs)**, **데이터 보존(Data Retention)**, **서버측 데이터 마스킹(ClickHouse로 검증)**, **보호된 프롬프트 라벨(Protected Prompt Labels)**, **UI 커스터마이징**, **조직 생성 허용목록(Organization Creators)**, 그리고 **Parquet 반출 ↔ ClickHouse 라운드트립**.

> 이 디렉토리는 워크숍의 **`-ee`(Enterprise Edition) 에디션**입니다 — OSS 트랙은 여전히 단독 실행되지만, 초점은 엔터프라이즈 기능 전반과 각 기능이 ClickHouse에 어떻게 안착(또는 ClickHouse로 검증)되는지에 있습니다.

### 🎯 왜 이 랩인가

대부분의 Langfuse 튜토리얼은 "Langfuse Cloud에 trace 보내기"에서 끝납니다. 이 랩은 **솔루션 아키텍트·플랫폼 팀**이 다음 질문에 답하기 위한 것입니다.

1. *self-hosted Langfuse 배포는 실제로 무엇으로 구성되는가?* (컨테이너 6개, 상태 저장 백엔드 4종)
2. *내 LLM 텔레메트리는 물리적으로 어디에 있고, 직접 조회할 수 있는가?* (네 — ClickHouse이며, 랩 04에서 비용/지연/품질 분석을 그 위에서 직접 실행)
3. *엔터프라이즈 라이선스를 추가하면 무엇을 얻는가?* (RBAC·SCIM·감사·보존 — UI 클릭 없이 전부 스크립트로)

### 🏗️ 아키텍처

```
                       ┌─────────────────┐
   LLM 앱       ──────►   langfuse-web   │  :3000  UI + Public API
   (SDK / OTEL)        │   langfuse-worker│  :3030  비동기 적재 + 잡
                       └───────┬─────────┘
            ┌──────────────────┼───────────────────┬───────────────┐
            ▼                  ▼                   ▼               ▼
      ┌──────────┐      ┌────────────┐       ┌─────────┐     ┌──────────┐
      │ Postgres │      │ ClickHouse │       │  Redis  │     │  MinIO   │
      │  OLTP    │      │   OLAP     │       │ 큐 +    │     │  S3 blob │
      │ users,   │      │ events_full│       │ 캐시    │     │ 원본이벤트│
      │ orgs,    │      │ events_core│       └─────────┘     │ 미디어,   │
      │ audit_log│      │ scores     │ ◄── 랩 03 & 04        │ 익스포트  │
      └──────────┘      └────────────┘                      └──────────┘
```

### 📁 파일 구조

```
langfuse-ee/
├── README.md                    # 이 문서
├── 01-up.sh                     # 래퍼 → _base/bin/up.sh v4: 스택 기동, 헬스 대기, 자격증명 출력
├── 02-generate-traces.py        # 래퍼 → _base/v4/seed_traces.py: 중첩 span/generation, 세션, 스코어
├── 03-clickhouse-explore.sql    # ClickHouse의 events_full/events_core/scores 테이블 탐색
├── 04-clickhouse-analytics.sql  # ClickHouse에서 직접 비용/지연/품질 분석
├── 05-ee-activate.sh            # 라이선스 키로 재기동, EE 활성화 검증
├── 06-ee-rbac-scim.sh           # 조직/프로젝트 프로비저닝, SCIM 사용자, 프로젝트 단위 RBAC
├── 07-ee-audit-retention.sh     # 데이터 보존 정책 + 감사 로그 조회
├── 08-ee-data-masking.sh        # 서버측 마스킹 → ClickHouse에서 부재 증명
│   ├── 08-generate-pii-traces.py#   ↳ 센티넬 시크릿/PII가 든 trace 전송
│   └── 08-verify-masking.sql    #   ↳ events_full에서의 ClickHouse 증명: 원문 시크릿 부재, [REDACTED_*] 존재, PASS/FAIL 판정 행
├── 09-ee-protected-prompts.sh   # 버전 관리 프롬프트 + 배포 라벨 + 보호된 라벨
├── 10-ee-instance-governance.sh # UI 커스터마이징 + 조직 생성 허용목록
├── 11-ee-parquet-export.sh      # Blob 스토리지 Parquet 반출 + ClickHouse s3() 라운드트립
└── 99-cleanup.sh                # 래퍼 → _base/bin/down.sh v4: 스택 종료 (--purge 로 볼륨까지 삭제)
```

스택 자체는 **다른 랩과 공유**하며 [`_base/`](../../../_base/README.md)에 있습니다 — compose 파일, EE / 마스킹 / 거버넌스 오버레이, 마스킹 사이드카, `.env.example`, 그리고 `bin/up.sh` · `bin/check.sh` · `bin/down.sh`:

```
_base/
├── .env.example                 # 시크릿, headless-init, EE 라이선스 키, SDK 키 (_base/.env 로 복사)
├── v3/ · v4/                    # 트랙별: versions.env(이미지 버전 고정) · requirements.txt(v4: langfuse, anthropic, opentelemetry-instrumentation-anthropic) · seed_traces.py
├── docker-compose.yml           # OSS 스택(이미지 버전 고정): web · worker · postgres · clickhouse · redis · minio
├── docker-compose.ee.yml        # EE 오버레이: 라이선스 키 + admin API 키 주입
├── docker-compose.masking.yml   # 랩 08 오버레이: 마스킹 사이드카 + worker 콜백 연결
├── docker-compose.governance.yml# 랩 10 오버레이: UI 커스터마이징 + 조직 생성 허용목록
├── masking/masking_service.py   # 랩 08: stdlib 전용 초경량 마스킹 콜백 사이드카
└── bin/                         # up.sh · check.sh · down.sh (첫 번째 인자: 트랙, v3 또는 v4)
```

### ✅ 사전 준비물

- **Docker + Docker Compose** (Mac/Windows는 Docker Desktop). CPU 4코어 / 16 GiB 이상 권장.
- 랩 02와 SDK 스크립트용 **Python 3.10+** (Langfuse Python SDK v4 요구사항. macOS 기본 `python3`는 더 낮으므로 `python3.12` 등을 사용). 고정된 패키지는 `pip install -r _base/v4/requirements.txt`로 설치.
- *(선택)* **Anthropic API 키**(`_base/.env`의 `ANTHROPIC_API_KEY`) — 랩 02와 eval 랩이 오프라인 시뮬레이션 대신 실제 모델(`claude-haiku-4-5`)을 호출합니다.
- 엔터프라이즈 스크립트(05–07)용 **`jq`** 와 **`curl`**.
- 랩 05–07용 **엔터프라이즈 라이선스 키** (OSS 트랙은 추가 준비물 없음).

### 🚀 빠른 시작 (OSS 트랙)

```bash
# 저장소 루트에서
cp _base/.env.example _base/.env   # 로컬 외 용도면 # CHANGEME 시크릿을 수정
cd labs/v4/langfuse-ee

# 1) 배포. 첫 기동 시 Postgres + ClickHouse 마이그레이션 (~2-3분)
./01-up.sh
#    → http://localhost:3000  (로그인: admin@example.com / workshop-admin-pw)
../../../_base/bin/check.sh v4     # 선택: 컨테이너 healthy, 마이그레이션 완료, SDK 키 유효 확인

# 2) 현실적인 trace 약 40건 적재 (완전 오프라인; Anthropic 키는 선택)
python3.12 -m venv ../../../.venv-v4 && source ../../../.venv-v4/bin/activate    # Python 3.10+
pip install -r ../../../_base/v4/requirements.txt
python 02-generate-traces.py

# 3) Langfuse의 ClickHouse 백엔드 탐색
docker exec -i langfuse-hols-v4-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse \
  --multiquery < 03-clickhouse-explore.sql

# 4) ClickHouse에서 직접 LLM 관측 분석 실행
docker exec -i langfuse-hols-v4-clickhouse-1 clickhouse-client -u clickhouse --password clickhouse \
  --multiquery < 04-clickhouse-analytics.sql
```

> 컨테이너 이름은 compose 프로젝트 이름(`langfuse-hols-v4`: `langfuse-hols-`에 트랙을 붙인 값, `_base/docker-compose.yml`에 고정)으로 정해지므로, 스택을 어느 디렉터리에서 띄웠는지에 더 이상 좌우되지 않습니다.

### 🏢 Enterprise 트랙

```bash
# _base/.env 에 키 입력:   LANGFUSE_EE_LICENSE_KEY=<발급받은 키>
#                          ADMIN_API_KEY=<임의의 강한 랜덤 문자열>

./05-ee-activate.sh          # EE 오버레이로 재배포; 라이선스 활성 검증
./06-ee-rbac-scim.sh         # 조직 → 조직 키 → 프로젝트 → SCIM 사용자 → RBAC 역할
./07-ee-audit-retention.sh   # 14일 보존 정책 설정 + 감사 로그 덤프
./08-ee-data-masking.sh      # 인제스트 시 시크릿 마스킹; ClickHouse에 도달하지 않음을 증명
./09-ee-protected-prompts.sh # 버전 관리 프롬프트 + 배포 라벨 + 보호된 라벨
./10-ee-instance-governance.sh # UI 커스터마이징 + 조직 생성 허용목록
./11-ee-parquet-export.sh    # 오브젝트 스토리지로 Parquet 반출 + ClickHouse s3() 라운드트립
```

### 🧩 EE 기능 커버리지

[Langfuse license-key 페이지](https://langfuse.com/self-hosting/license-key)가 명시하는 모든 Enterprise entitlement을, 이를 실습하는 랩에 매핑:

| Enterprise entitlement | 랩 | ClickHouse 관점 |
|---|---|---|
| Instance Management API | 05 | — |
| Org Management API & SCIM | 06 | — |
| 프로젝트 단위 RBAC 역할 | 06 | — |
| 감사 로그(Audit Logs) | 07 | (감사 로그는 Postgres) |
| 데이터 보존(Data Retention) | 07 | 야간 worker가 오래된 행을 ClickHouse에서 삭제 |
| **서버측 데이터 마스킹** | 08 | **증명이 ClickHouse에서 실행** — 원문 시크릿 미저장 |
| **보호된 프롬프트 라벨** | 09 | (프롬프트는 Postgres) |
| **UI 커스터마이징** | 10 | — |
| **조직 생성 허용목록** | 10 | — |
| Parquet Blob 스토리지 반출* | 11 | **ClickHouse `s3()`가 Parquet 쓰기+재조회** |

\* 스케줄 blob 스토리지 반출은 모든 self-hosted 프로젝트에서 사용 가능(라이선스 게이트 아님)하지만, 엔터프라이즈 데이터플랫폼/아카이브 스토리이자 가장 ClickHouse 친화적인 랩이므로 엔터프라이즈 트랙에 포함했습니다.

### 📖 랩 워크스루

#### 01 — 스택 배포

[docker-compose.yml](../../../_base/docker-compose.yml)의 6개 컨테이너를 (공유 [`_base/bin/up.sh`](../../../_base/bin/up.sh)로) 띄우고 `GET /api/public/health`가 OK를 반환할 때까지 대기합니다. compose 파일은 **headless 초기화**(`_base/.env`의 `LANGFUSE_INIT_*`)로 최초 조직·프로젝트·사용자·API 키를 부팅 시 자동 생성하므로, 데이터 전송 전 **UI 클릭 작업이 전혀 필요 없습니다**. 주목할 점: ClickHouse는 단일 노드(`CLICKHOUSE_CLUSTER_ENABLED=false`), 모든 백엔드는 **UTC**(Langfuse 필수 요건), MinIO가 S3 호환 blob 스토리지를 제공.

#### 02 — Trace 생성

**Langfuse Python SDK (v4, OpenTelemetry 네이티브)** 로 고객 지원 RAG 어시스턴트를 시뮬레이션합니다. 각 trace는 중첩 observation 트리입니다.

```python
with lf.start_as_current_observation(as_type="span", name="support-request",
                                     input={"question": ...}) as root:
    with propagate_attributes(trace_name="support-request", user_id=..., session_id=...,
                              tags=[...], metadata={"tier": ...}):          # 아래 모든 observation에 기록됨
        with lf.start_as_current_observation(as_type="span", name="retrieve-context"): ...
        with lf.start_as_current_observation(as_type="generation",
                                             name="answer-generation", model="gpt-4o") as gen:
            gen.update(output=..., usage_details={"input": ..., "output": ...})
    root.update(output=...)
lf.create_score(name="user-thumbs", value=1, data_type="BOOLEAN", trace_id=...)
lf.flush()   # 짧은 스크립트에서 필수 — 종료 전 비동기 버퍼 전송
```

SDK v4는 `update_current_trace()`를 `propagate_attributes()`로 대체했습니다. trace 속성은 블록 안에서 생성되는 모든 observation에 기록되고(metadata는 `dict[str, str]`, 값은 200자 이하), trace의 input/output은 루트 observation에 둡니다. 모델·사용자·세션·태그(`env`/`feature`/`tier`)·토큰 사용량·지연·오류(~8%)를 다양화하고 스코어를 부착합니다. 비용은 모델명 + 토큰 사용량으로부터 Langfuse가 **자동 계산**하지만, usage 키가 모델 가격표의 키와 일치할 때만 계산됩니다. 그래서 생성기는 `input` / `output`을 보내고, 가격 정의가 있는 모델(`gpt-4o-mini`, `gpt-4o`, `claude-haiku-4-5`)만 시뮬레이션합니다. 기본은 오프라인이며, `_base/.env`에 `ANTHROPIC_API_KEY`를 설정하면 공식 `anthropic` SDK로 실제 호출하고 `opentelemetry-instrumentation-anthropic`이 추적합니다(호출은 모델·토큰·비용이 있는 `GENERATION`으로 나타남).

#### 03 — ClickHouse 백엔드 탐색

Langfuse가 마이그레이션한 `default` 데이터베이스에 대한 순수 탐색: `SHOW TABLES`, `DESCRIBE events_full/events_core/scores`, 엔진 + 정렬 키 + 파티셔닝, 행 수, 한 trace의 전체 observation 트리, 월별 파티션 레이아웃. **trace 행은 더 이상 없습니다. trace는 `events_full` / `events_core`의 루트 행(`is_app_root`)이고, 그 단계들은 같은 `trace_id`를 가진 나머지 행이며, 스코어는 `scores`에 저장됩니다.** v3 테이블 `traces`와 `observations`는 남아 있지만 비어 있으며, 랩이 그 행 수(0)를 출력해 v4가 다른 곳에 쓴다는 증거로 보여 줍니다.

> ClickHouse 스키마는 Langfuse 내부 구현 세부사항이며 **안정적인 API가 아닙니다** — v3 → v4에서 모든 것이 `traces` / `observations`에서 `events_full` / `events_core`로 옮겨졌고, 컬럼명은 다시 바뀔 수 있습니다. 설치된 버전의 정답은 항상 `DESCRIBE` 출력입니다.

#### 04 — ClickHouse 분석

SA 관점의 핵심: Langfuse UI가 답하는 질문들을 순수 ClickHouse SQL로 표현하고, 이 워크로드에 ClickHouse가 왜 맞는지 보여줍니다.

| 쿼리 | ClickHouse 기능 |
|---|---|
| 모델별 비용·토큰 | `type = 'GENERATION'` 행의 `total_cost`와 `usage_details` `Map`에 대한 `sum()` |
| 모델별 지연 p50/p95/p99 | `dateDiff('millisecond', …)`에 대한 `quantile()` |
| 모델별 오류율 | `countIf(level = 'ERROR')` 조건부 집계 |
| 고객 등급별 비용 | `metadata_values[indexOf(metadata_names, 'tier')]` — metadata는 병렬 배열 두 개; **JOIN 없음** |
| 고객 등급별 품질 | 남은 유일한 JOIN: `scores.trace_id = events_core.trace_id` |
| 추천(thumbs-up)율 / 그라운딩 | `scores` 테이블의 `sumIf`/`avgIf` |
| 사용자별 비용 리더보드 | `events_core` 한 번 스캔 — `user_id`가 모든 행에 있음 |
| 일별 추이 / 세션 깊이 | 시간 버킷팅 + `uniqExactIf` / `countIf(is_app_root)` |

이 랩의 v4 교훈: v3 쿼리는 generation의 사용자·등급을 알기 위해 `traces`와 `observations`를 JOIN했습니다. v4에서는 모든 observation 행이 이미 그 값을 가지고 있어 JOIN이 사라집니다.

#### 05 — Enterprise 활성화

[docker-compose.ee.yml](../../../_base/docker-compose.ee.yml)로 `langfuse-web` + `langfuse-worker`를 재배포하여 `LANGFUSE_EE_LICENSE_KEY`를 **양쪽** 컨테이너에 주입합니다(+ `ADMIN_API_KEY`). 유효한 라이선스가 있을 때만 응답하는 **Instance Management API**(`/api/admin/organizations`)로 활성화를 검증합니다.

#### 06 — RBAC & SCIM

완전한 셀프서비스 관리 체인을 스크립트로:

```
ADMIN_API_KEY → 조직 생성 → 조직 범위 API 키 발급
     조직 키    → 프로젝트 생성 → 프로젝트 API 키 발급
     조직 키    → SCIM: 사용자 프로비저닝 → 조직(ORG) 역할 부여
     조직 키    → 조직 역할을 덮어쓰는 프로젝트 단위 역할 부여  (EE)
```

역할: `OWNER`(전체) · `ADMIN`(설정 + 멤버) · `MEMBER`(조회 + 스코어 생성) · `VIEWER`(읽기 전용). 마지막에 Bob에게 조직 전체는 `VIEWER`, 한 프로젝트에서는 `ADMIN`을 부여 — **프로젝트 단위 RBAC는 엔터프라이즈 기능**입니다.

#### 07 — 감사 로그 & 데이터 보존

- **데이터 보존**: `PUT /api/public/projects/{id}`로 프로젝트에 14일 보존을 설정. 0이 아닌 값은 data-retention entitlement(EE)가 필요하며 — OSS에서는 동일 호출이 거부됩니다. 야간 worker가 보존 기간을 넘긴 trace/observation/score를 ClickHouse에서 직접 삭제합니다.
- **감사 로그**: Postgres의 감사 테이블을 탐지하여 최근 누가/무엇을/언제 기록을 — 랩 06이 방금 만든 조직/프로젝트/멤버십 변경을 before/after 전체 상태와 함께 — 덤프합니다.

#### 08 — 서버측 데이터 마스킹 ([08-ee-data-masking.sh](08-ee-data-masking.sh))

**ClickHouse로 검증 가능한** 핵심 EE 데모입니다. 초경량 마스킹 콜백 사이드카([masking_service.py](../../../_base/masking/masking_service.py), stdlib 전용)를 [docker-compose.masking.yml](../../../_base/docker-compose.masking.yml)로 worker의 `LANGFUSE_INGESTION_MASKING_CALLBACK_URL`에 연결합니다. Langfuse는 OTLP로 인제스트된 각 trace를 콜백에 POST하고, 콜백은 시크릿/PII 패턴(API 키, 신용카드, 이메일, 주민등록번호)을 리댁션한 뒤 동일 구조로 반환합니다 — **저장 이전에** 일어납니다.

[08-generate-pii-traces.py](08-generate-pii-traces.py)가 4개 센티넬 시크릿이 든 trace(input·output·metadata에 포함)를 보내고, [08-verify-masking.sql](08-verify-masking.sql)이 **ClickHouse에서 직접**, 전체 페이로드가 잘리지 않고 들어 있는 `events_full`에서 결과를 증명합니다:

```sql
-- 전부 0이어야 함: 원문 시크릿이 OLAP 스토어에 도달하지 않음 (input, output, metadata)
countIf(position(input, '0xDEADBEEF01') > 0 OR position(output, '0xDEADBEEF01') > 0
     OR arrayExists(v -> position(v, '0xDEADBEEF01') > 0, metadata_values))  AS leaked_api_key
-- 0보다 커야 함: 리댁션 placeholder는 안착
countIf(position(input, '[REDACTED_') > 0 OR position(output, '[REDACTED_') > 0)  AS masked_payload_rows
```

파일은 명시적인 **`verdict`** 행 하나로 끝납니다. pii-demo 행이 적재되었고 **그중 일부가** `[REDACTED_*]` placeholder를 가지며 **모든 leak 카운트가 `0`일 때만** `PASS`, 아니면 `FAIL`이며, `08-ee-data-masking.sh`는 `FAIL`이면 `1`로 종료합니다. 테이블이 비어 있으면 "leak 0"은 아무것도 증명하지 못하므로, `./08-ee-data-masking.sh --selftest`가 양성 대조군입니다. 같은 SQL을 빈 `events_full` 복사본에 실행해 verdict가 `FAIL`이어야 통과합니다.

핵심: 마스킹은 **OTLP 엔드포인트**(`/api/public/otel` = SDK v3+)에만 적용; `FAIL_CLOSED=true`면 콜백 오류 시 이벤트를 드롭(보안 기본값); 콜백 본문은 **OTLP Trace Request proto(JSON)** 이므로 사이드카는 JSON을 딥워크하며 문자열 리프만 재작성합니다.

#### 09 — 보호된 프롬프트 라벨 ([09-ee-protected-prompts.sh](09-ee-protected-prompts.sh))

프롬프트 거버넌스. 버전 관리 프롬프트를 생성하고 `production` 라벨을 v1 → v2로 API로 이동, 현재 production 프롬프트를 조회한 뒤, 그 버전들이 **Postgres**에 저장됨(프롬프트는 OLTP — ClickHouse 아님)과 **감사 로그**의 대응 행(랩 07과 연결)을 보여줍니다. 마무리는 EE **보호된 라벨**: Project Settings에서 `production`을 보호로 지정하면 랩 06의 역할이 적용되어 Bob(`VIEWER`)·Alice(`MEMBER`)는 라벨을 재지정/삭제할 수 없고 Owner/Admin만 가능합니다. 보호 토글은 UI 전용(공개 API 없음)이며, 강제는 사용자 역할 기준입니다.

#### 10 — 인스턴스 거버넌스 ([10-ee-instance-governance.sh](10-ee-instance-governance.sh))

두 가지 인스턴스 레벨 제어를 [docker-compose.governance.yml](../../../_base/docker-compose.governance.yml)로 env 주입: **UI 커스터마이징**(`LANGFUSE_UI_LOGO_*`, `LANGFUSE_UI_FEEDBACK/DOCUMENTATION/SUPPORT_HREF` — 코브랜딩 + 도움말 링크 내부화)과 **조직 생성 허용목록**(`LANGFUSE_ALLOWED_ORGANIZATION_CREATORS` — 목록의 이메일만 새 조직 생성 가능). 스크립트는 `langfuse-web`를 재배포한 뒤 실행 중 컨테이너에 `exec … env | grep`으로 **변수가 실제 주입되었음을 증명**하고, UI 검증 체크리스트를 출력합니다.

#### 11 — Parquet 반출 ↔ ClickHouse ([11-ee-parquet-export.sh](11-ee-parquet-export.sh))

엔터프라이즈 데이터플랫폼/아카이브 스토리를 두 파트로. **(A)** `PUT /api/public/integrations/blob-storage`로 스케줄 **Parquet** blob 스토리지 반출 설정(type `S3_COMPATIBLE`, 워크숍 MinIO 지정). v4에서 통합의 `exportSource`는 enriched observations 소스인 `OBSERVATIONS_V2`여야 합니다. 레거시 `LEGACY_TRACES_OBSERVATIONS` 소스는 v3 테이블을 읽으며, Langfuse export 문서는 레거시 소스를 기본 `events_only` 모드에서 쓸 수 없다고 밝힙니다. **(B)** 그것을 구동하는 바로 그 primitive를 ClickHouse로 **라이브** 시연 — 스케줄러를 기다리지 않음:

```sql
INSERT INTO FUNCTION s3('http://minio:9000/langfuse/exports/manual/events_full.parquet',
                        'minio', 'miniosecret', 'Parquet')
  SELECT * FROM default.events_full FINAL WHERE is_deleted = 0 SETTINGS s3_truncate_on_insert = 1;
SELECT count() FROM s3('http://minio:9000/langfuse/exports/manual/events_full.parquet',
                       'minio', 'miniosecret', 'Parquet');   -- 곧바로 다시 읽기
```

스크립트는 원본 행 수와 Parquet 행 수를 나란히 출력하고, 다르면 `1`로 종료합니다.

랩 07과 **archive-then-delete**로 짝을 이룸: 보존 삭제 전에 반출. SA 함정 반영 — self-hosted에서 **ClickHouse < 25.11**은 Parquet 반출 실패가 안 뜰 수 있음(불완전 파일인데 "성공"). ≥ 25.11로 업그레이드하거나 신뢰할 수 있는 실패 감지를 위해 CSV/JSON 사용.

### 🔑 기억할 함정들

| | 노트 |
|---|---|
| **두 DB, 두 역할** | Postgres = OLTP(사용자·조직·프롬프트·**감사 로그**). ClickHouse = OLAP(**events_full / events_core, scores**). Postgres에서 trace를 찾지 말 것 — v4에서는 `traces` 테이블에서도 찾을 수 없음. |
| **모든 곳에서 UTC** | ClickHouse **와** Postgres 모두 UTC여야 함. 아니면 쿼리가 틀리거나 빈 결과를 반환. compose가 설정함. |
| **스크립트에서 `flush()`** | SDK는 비동기 전송. `lf.flush()` 없이 종료하는 짧은 스크립트는 trace를 잃음. |
| **비용은 파생값** | `usage_details`(토큰)를 보내면 Langfuse가 모델 가격표로 비용 계산 — 단, usage 키가 모델 가격표의 키와 일치할 때만. `input` / `output`을 보내고, 정의가 있는 모델명을 사용(`gpt-4o`, `claude-haiku-4-5`). |
| **trace 속성은 observation 단위** | SDK v4에는 `update_current_trace()`가 없음. 작업을 `propagate_attributes(...)`로 감쌀 것. metadata는 `dict[str, str]`, 값은 200자 이하. |
| **전역 RNG에 seed 금지** | `random.seed()`는 OpenTelemetry가 매 실행마다 같은 trace/span id를 쓰게 만들고, 중복 행은 `FINAL`로도 합쳐지지 않음. 생성기는 별도의 `random.Random`을 사용. |
| **EE 라이선스는 양쪽 컨테이너에** | `LANGFUSE_EE_LICENSE_KEY`는 `langfuse-web`과 `langfuse-worker` 모두에 필요. 오버레이가 처리. |
| **CH 스키마 ≠ API** | 랩/디버깅용으로 ClickHouse를 직접 조회하되 스키마는 불안정하다고 간주. 앱에서는 Public API / SDK query helper / Blob Storage Export 사용. |
| **`retention=0` = 영구** | 0이 아닌 최소 보존은 3일. 삭제 전 보관이 필요하면 Blob Storage Export와 병행. |

### 📝 검증 상태

**2026-10-10**에 **Langfuse v4.56.0 / SDK 4.17.0 / ClickHouse 26.8.22.13**에서 **end-to-end 검증**했습니다(v4 트랙, [#55](https://github.com/litkhai/langfuse-hols/issues/55)).

- **스택:** [`_base/`](../../../_base/README.md)의 고정 스택(`_base/v4/versions.env`)입니다. Docker 29.8.2, Compose v5.5.1, Python 3.12.14, 새 볼륨, 기본 `events_only` 쓰기 모드를 썼습니다.
- **EE:** 실제 엔터프라이즈 라이선스 키를 썼습니다.
- **모델 호출:** 랩 01–11은 오프라인으로 돌렸고, 랩 02는 실제 Anthropic 호출(`claude-haiku-4-5`)로도 한 번 더 돌렸습니다.

01 → 11 전체 실행의 콘솔 출력 원본은 **[lab-output.md](lab-output.md)**에 있습니다(블로그용).

| 단계 | 결과 |
|---|---|
| `01` 스택 기동 | 컨테이너 6개; `/api/public/health` → 버전 `4.56.0`; `_base/bin/check.sh v4` 전부 PASS(health 버전이 고정 버전과 같음, ClickHouse 마이그레이션 51/51 포함) |
| `02` 트레이스 생성 | 오프라인 40건 + 실제 `claude-haiku-4-5` 호출 5건(OpenTelemetry로 트레이스되고, Langfuse가 계산한 비용은 5건에 $0.001303) |
| `03` 탐색 | 데이터는 `events_full`·`events_core`(각 158행)와 `scores`(88행)에 있음. v3 `traces`·`observations` 테이블은 있으나 **0행** |
| `04` 분석 | 8개 쿼리 모두 `events_core`에서 결과 반환; 실제 `claude-haiku-4-5-20251001` 호출을 포함해 모든 모델의 비용이 0이 아님; 조인 불필요 |
| `05` EE 활성화 | Instance Management API `/api/admin/organizations` → HTTP 200 (라이선스 유효) |
| `06` RBAC/SCIM | 조직 + 프로젝트 + SCIM 사용자 2명 + 프로젝트 단위 역할 오버라이드, 전부 API로 |
| `07` 감사/보존 | 14일 보존 설정(`retentionDays: 14`); 감사 로그는 9행: 랩 06의 조직 생성, 조직 멤버십 2개와 그 수정 2건, 역할 오버라이드를 담은 프로젝트 멤버십, 그 조직의 API 키 2개, admin 키로 `ch-workshop` 조직에 만든 API 키(프로젝트 생성·SCIM 사용자는 이 목록에 없음). 4.53.0에서는 멤버십 수정과 프로젝트 멤버십 없이 6행이었음 |
| `08` 데이터 마스킹 | 판정 **PASS**: pii-demo 24행 마스킹, `events_full`의 input·output·metadata 전체에서 누출 `0`; 사이드카 로그 **108 redactions**. `--selftest`: 빈 테이블에서는 판정이 FAIL |
| `09` 보호된 프롬프트 | v1→v2 라벨 이동(v1 `labels={}`, v2 `{production,latest}`); 프롬프트 행은 Postgres에; `create prompt` 감사 2건 |
| `10` 거버넌스 | 컨테이너 env에서 `LANGFUSE_UI_*` + `LANGFUSE_ALLOWED_ORGANIZATION_CREATORS` 전부 확인 |
| `11` parquet 반출 | 통합 API가 `OBSERVATIONS_V2` export source와 함께 **`fileType: PARQUET`를 허용**; CH `s3()` 라운드트립 **182 == 182**. 한 시간 주기 작업은 정리 전에 실행되지 않아 파일 생성까지는 증명하지 못함 |

> **버전 드리프트(랩 11), 고정으로 해소.** v3.197.1에서는 공개 OpenAPI 스펙에 있는데도 통합 API가 `fileType: PARQUET`를 HTTP 400으로 거부했습니다(`JSON`/`CSV`/`JSONL`만 허용). v4.48.0에서 허용됐고, 고정한 **v4.56.0**에서도 허용됩니다(2026-10-10). 스크립트는 여전히 `PARQUET`를 먼저 시도하고 `JSONL`로 폴백하므로, 더 오래된 이미지에서도 동작합니다. 문서가 아니라 *실행 중인 이미지* 기준으로 API를 확인하세요.

런타임에서 확인해 랩에 반영한 두 가지:

1. **v4는 observation을 `events_full`·`events_core`에 씁니다.** 예전 테이블은 비어 있습니다. 그래서 분석 쿼리는 `events_core FINAL`을, 마스킹 검증은 전체 원본이 있는 `events_full`을 `FINAL` + `WHERE is_deleted = 0`으로 읽습니다.
2. **비용은 모델 가격 정의에 있는 usage 키에 대해서만 계산됩니다.** v4.48.0에서 측정해 보니 `gpt-4o-mini`는 `input_tokens`/`output_tokens`로 보내면 `total_cost = 0`이고, `input`/`output`으로 보내면 비용이 계산됩니다. 그래서 생성기는 `input`/`output`을 보냅니다.

설치 버전의 정답은 랩 03의 `DESCRIBE` 출력입니다.

### 🔍 추가 자료

- [Self-host Langfuse — 개요](https://langfuse.com/self-hosting)
- [Docker Compose 배포](https://langfuse.com/self-hosting/deployment/docker-compose)
- [Langfuse용 ClickHouse](https://langfuse.com/self-hosting/deployment/infrastructure/clickhouse)
- [Enterprise License Key](https://langfuse.com/self-hosting/license-key)
- [Access Control (RBAC)](https://langfuse.com/docs/administration/rbac) · [SCIM & Org API](https://langfuse.com/docs/administration/scim-and-org-api)
- [Audit Logs](https://langfuse.com/docs/administration/audit-logs) · [Data Retention](https://langfuse.com/docs/administration/data-retention)
- [서버측 데이터 마스킹](https://langfuse.com/self-hosting/security/data-masking) · [보호된 프롬프트 라벨](https://langfuse.com/docs/prompt-management/features/prompt-version-control)
- [UI 커스터마이징](https://langfuse.com/self-hosting/administration/ui-customization) · [Organization Creators](https://langfuse.com/self-hosting/administration/organization-creators)
- [Blob 스토리지 반출](https://langfuse.com/docs/api-and-data-platform/features/export-to-blob-storage) · [ClickHouse `s3` 테이블 함수](https://clickhouse.com/docs/sql-reference/table-functions/s3)
- [Python SDK](https://langfuse.com/docs/observability/sdk/overview) · [Python SDK v3 → v4](https://langfuse.com/docs/observability/sdk/upgrade-path/python-v3-to-v4) · [서버 v3 → v4](https://langfuse.com/self-hosting/upgrade/upgrade-guides/upgrade-v3-to-v4)
- [Anthropic 연동 (OpenTelemetry)](https://langfuse.com/integrations/model-providers/anthropic)

### 📝 라이선스

[MIT](../../../LICENSE) — same as the rest of the repository.

### 👤 작성자

Ken Lee (ClickHouse Solution Architect) — ken.lee@clickhouse.com
작성일: 2026-06-25 · EE 트랙(랩 08–11) 추가: 2026-07-26

---

**Happy Tracing! 🔭**

질문이나 이슈는 메인 [langfuse-hols README](../../../README.md)를 참조하세요.
