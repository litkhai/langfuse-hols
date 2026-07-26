# Self-Hosting Langfuse on ClickHouse — Workshop (OSS + Enterprise)

[English](#english) | [한국어](#한국어)

---

## English

A hands-on, end-to-end workshop for **self-hosting [Langfuse](https://langfuse.com)** — the open-source LLM observability platform — and then looking *under the hood* at the **ClickHouse backend** that powers it.

Langfuse v3 stores all of its OLTP state (users, orgs, projects, prompts, the audit log) in **Postgres**, but every **trace, observation, and score** lands in **ClickHouse**. That makes Langfuse a real, production-grade ClickHouse application you can stand up in minutes — and a great way to *feel* why ClickHouse is the right OLAP engine for high-volume, append-only LLM telemetry.

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
      │ users,   │      │ traces,    │       │  cache  │     │ raw events│
      │ orgs,    │      │ observations│      └─────────┘     │ media,    │
      │ audit_log│      │ scores     │ ◄── labs 03 & 04      │ exports   │
      └──────────┘      └────────────┘                      └──────────┘
```

### 📁 File Structure

```
langfuse-ee/
├── README.md                    # This file
├── .env.example                 # Secrets, headless-init, EE license key, SDK keys
├── docker-compose.yml           # OSS stack: web · worker · postgres · clickhouse · redis · minio
├── docker-compose.ee.yml        # EE overlay: injects license key + admin API key
├── docker-compose.masking.yml   # Lab 08 overlay: masking sidecar + worker callback wiring
├── docker-compose.governance.yml# Lab 10 overlay: UI customization + org-creators allowlist
├── 01-up.sh                     # Bring the stack up, wait for health, print credentials
├── 02-generate-traces.py        # Python SDK v3+: nested spans/generations, sessions, scores
├── 03-clickhouse-explore.sql    # Discover the traces/observations/scores tables in ClickHouse
├── 04-clickhouse-analytics.sql  # Cost / latency / quality analytics straight on ClickHouse
├── 05-ee-activate.sh            # Restart with the license key, verify EE is active
├── 06-ee-rbac-scim.sh           # Org/project provisioning, SCIM users, project-level RBAC
├── 07-ee-audit-retention.sh     # Data-retention policy + read the audit log
├── 08-ee-data-masking.sh        # Server-side masking, PROVEN absent in ClickHouse
│   ├── masking_service.py       #   ↳ tiny stdlib masking-callback sidecar
│   ├── 08-generate-pii-traces.py#   ↳ send traces containing sentinel secrets/PII
│   └── 08-verify-masking.sql    #   ↳ ClickHouse proof: raw secrets gone, [REDACTED_*] present
├── 09-ee-protected-prompts.sh   # Versioned prompts + deployment labels + protected labels
├── 10-ee-instance-governance.sh # UI customization + organization-creators allowlist
├── 11-ee-parquet-export.sh      # Blob-storage Parquet export + ClickHouse s3() round-trip
└── 99-cleanup.sh                # Tear the stack down (--purge to wipe volumes)
```

### ✅ Prerequisites

- **Docker + Docker Compose** (Docker Desktop on Mac/Windows). Give it ≥ 4 CPU / 16 GiB.
- **Python 3.9+** for lab 02.
- **`jq`** and **`curl`** for the enterprise scripts (05–07).
- An **enterprise license key** for labs 05–07 (the OSS track needs nothing extra).

### 🚀 Quick Start (OSS track)

```bash
cd usecase/langfuse-ee
cp .env.example .env            # edit the # CHANGEME secrets for anything non-local

# 1) Deploy. First boot runs Postgres + ClickHouse migrations (~2-3 min).
./01-up.sh
#    → http://localhost:3000  (login: admin@example.com / workshop-admin-pw)

# 2) Push ~40 realistic traces (runs fully offline; no LLM key needed)
python -m venv .venv && source .venv/bin/activate
pip install "langfuse>=3" openai
python 02-generate-traces.py

# 3) Explore Langfuse's ClickHouse backend
docker compose exec -T clickhouse clickhouse-client -u clickhouse --password clickhouse \
  --multiquery < 03-clickhouse-explore.sql

# 4) Run LLM-observability analytics directly on ClickHouse
docker compose exec -T clickhouse clickhouse-client -u clickhouse --password clickhouse \
  --multiquery < 04-clickhouse-analytics.sql
```

### 🏢 Enterprise Track

```bash
# Put your key in .env:   LANGFUSE_EE_LICENSE_KEY=<your-key>
#                         ADMIN_API_KEY=<any-strong-random-string>

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

Brings up the six containers from [docker-compose.yml](docker-compose.yml) and blocks until `GET /api/public/health` returns OK. The compose file uses **headless initialization** (`LANGFUSE_INIT_*` in `.env`) to auto-create the first organization, project, user, and API keys on boot — so there are **no UI click-ops** before you can send data. Key things to notice: ClickHouse runs single-node (`CLICKHOUSE_CLUSTER_ENABLED=false`), all backends run in **UTC** (a hard Langfuse requirement), and MinIO provides S3-compatible blob storage.

#### 02 — Generate traces ([02-generate-traces.py](02-generate-traces.py))

Uses the **Langfuse Python SDK (v3+, OpenTelemetry-native)** to simulate a customer-support RAG assistant. Each trace is a nested observation tree:

```python
with lf.start_as_current_observation(as_type="span", name="support-request") as root:
    lf.update_current_trace(user_id=..., session_id=..., tags=[...])     # trace metadata
    with lf.start_as_current_observation(as_type="span", name="retrieve-context"): ...
    with lf.start_as_current_observation(as_type="generation",
                                         name="answer-generation", model="gpt-4o") as gen:
        gen.update(output=..., usage_details={"input_tokens": ..., "output_tokens": ...})
lf.create_score(name="user-thumbs", value=1, data_type="BOOLEAN", trace_id=...)
lf.flush()   # critical in short scripts — sends the async buffer before exit
```

It varies model, user, session, tags (`env`/`feature`/`tier`), token usage, latency, errors (~8%), and attaches scores. Cost is computed **automatically** by Langfuse from the model name + token usage. Runs offline by default; set `OPENAI_API_KEY` to make real calls via the drop-in `from langfuse.openai import openai`.

#### 03 — Explore the ClickHouse backend ([03-clickhouse-explore.sql](03-clickhouse-explore.sql))

Pure discovery against the `default` database Langfuse migrated into: `SHOW TABLES`, `DESCRIBE traces/observations/scores`, engine + sort-key + partitioning, row counts, the full observation tree for one trace, and the monthly partition layout. **A trace is one row in `traces`; its steps are rows in `observations` linked by `trace_id`; scores live in `scores`.**

> The ClickHouse schema is an internal Langfuse detail, **not a stable API** — column names can change across major versions. The `DESCRIBE` output is always the source of truth for your installed version.

#### 04 — Analytics on ClickHouse ([04-clickhouse-analytics.sql](04-clickhouse-analytics.sql))

The SA payoff: the same questions the Langfuse UI answers, expressed as plain ClickHouse SQL — and a showcase of why ClickHouse fits this workload.

| Query | ClickHouse primitive |
|---|---|
| Spend & tokens by model | `sum()` over `Map` columns (`usage_details`, `cost_details`) |
| Latency p50/p95/p99 per model | `quantile()` over `dateDiff('millisecond', start_time, end_time)` |
| Error rate per model | `countIf(level = 'ERROR')` conditional aggregation |
| Cost & quality by customer tier | `arrayFirst()` over `tags` + JOIN to observations |
| Thumbs-up rate / grounding | `sumIf`/`avgIf` over the `scores` table |
| Per-user spend leaderboard | trace ↔ observation JOIN, cost attribution |
| Daily trend / session depth | time bucketing + `uniqExact` |

#### 05 — Activate Enterprise ([05-ee-activate.sh](05-ee-activate.sh))

Redeploys `langfuse-web` + `langfuse-worker` with [docker-compose.ee.yml](docker-compose.ee.yml), which injects `LANGFUSE_EE_LICENSE_KEY` into **both** containers (plus `ADMIN_API_KEY`). It verifies activation by hitting the **Instance Management API** (`/api/admin/organizations`) — which only responds when a valid license is present.

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

The flagship **ClickHouse-verifiable** EE demo. A tiny masking-callback sidecar ([masking_service.py](masking_service.py), stdlib only) is wired to the worker via [docker-compose.masking.yml](docker-compose.masking.yml) as `LANGFUSE_INGESTION_MASKING_CALLBACK_URL`. Langfuse POSTs each OTLP-ingested trace to it; the service redacts anything matching a secret/PII pattern (API keys, credit cards, e-mails, KR 주민등록번호) and returns the same structure — **before** the trace is persisted.

[08-generate-pii-traces.py](08-generate-pii-traces.py) sends traces containing four sentinel secrets, then [08-verify-masking.sql](08-verify-masking.sql) proves the payoff **directly on ClickHouse**:

```sql
-- want ALL ZERO: no raw secret reached the OLAP store
countIf(position(toString(input), '0xDEADBEEF01') > 0 OR position(toString(output), '0xDEADBEEF01') > 0)  AS leaked_api_key
-- want > 0: the redaction placeholders did land
countIf(position(toString(input), '[REDACTED_') > 0)  AS masked_observation_rows
```

Key facts: masking applies **only** to the OTLP endpoint (`/api/public/otel` = SDK v3+); `FAIL_CLOSED=true` drops events if the callback errors (secure default); the callback body is an **OTLP Trace Request proto in JSON**, so the sidecar deep-walks the JSON and only rewrites string leaves.

#### 09 — Protected Prompt Labels ([09-ee-protected-prompts.sh](09-ee-protected-prompts.sh))

Prompt governance. The script creates a versioned prompt, moves the `production` label from v1 → v2 via the API, resolves the current production prompt, then shows those versions living in **Postgres** (prompts are OLTP — not ClickHouse) and the matching rows in the **audit log** (ties back to lab 07). The capstone is the EE **protected label**: once `production` is marked protected in Project Settings, the lab-06 roles apply — Bob (`VIEWER`) and Alice (`MEMBER`) can no longer repoint or delete it, only Owner/Admin can. Protection is toggled in the UI (no public API); enforcement is per user role.

#### 10 — Instance Governance ([10-ee-instance-governance.sh](10-ee-instance-governance.sh))

Two instance-level controls, both env-driven via [docker-compose.governance.yml](docker-compose.governance.yml): **UI Customization** (`LANGFUSE_UI_LOGO_*`, `LANGFUSE_UI_FEEDBACK/DOCUMENTATION/SUPPORT_HREF` — co-brand + point help links inward) and the **Organization-Creators allowlist** (`LANGFUSE_ALLOWED_ORGANIZATION_CREATORS` — only listed emails may create new orgs). The script redeploys `langfuse-web`, then `exec … env | grep`s the running container to **prove the vars are live**, and prints a UI verification checklist.

#### 11 — Parquet Export ↔ ClickHouse ([11-ee-parquet-export.sh](11-ee-parquet-export.sh))

The enterprise data-platform / archival story, in two parts. **(A)** Configure a scheduled **Parquet** blob-storage export via `PUT /api/public/integrations/blob-storage` (type `S3_COMPATIBLE`, pointed at the workshop MinIO). **(B)** Demonstrate the exact primitive that powers it, **live**, with ClickHouse — no waiting on the scheduler:

```sql
INSERT INTO FUNCTION s3('http://minio:9000/langfuse/exports/manual/traces.parquet',
                        'minio', 'miniosecret', 'Parquet')
  SELECT * FROM default.traces FINAL WHERE is_deleted = 0 SETTINGS s3_truncate_on_insert = 1;
SELECT count() FROM s3('http://minio:9000/langfuse/exports/manual/traces.parquet',
                       'minio', 'miniosecret', 'Parquet');   -- read it right back
```

Pairs with lab 07 as **archive-then-delete**: export before retention deletes. SA gotcha baked in — on self-hosted, **ClickHouse < 25.11** may not surface Parquet export failures (a run can "succeed" with an invalid file); upgrade to ≥ 25.11 or use CSV/JSON for reliable failure detection.

### 🔑 Gotchas worth remembering

| | Note |
|---|---|
| **Two databases, two jobs** | Postgres = OLTP (users, orgs, prompts, **audit log**). ClickHouse = OLAP (**traces, observations, scores**). Don't look for traces in Postgres. |
| **UTC everywhere** | ClickHouse **and** Postgres must run in UTC, or queries return wrong/empty results. The compose file sets this. |
| **`flush()` in scripts** | The SDK ships data asynchronously. A short script that exits without `lf.flush()` loses its traces. |
| **Cost is derived** | You send `usage_details` (tokens); Langfuse computes cost from its model price table. Use model names it knows (`gpt-4o`, `claude-3-5-sonnet-…`). |
| **EE license on BOTH containers** | `LANGFUSE_EE_LICENSE_KEY` must be set on `langfuse-web` *and* `langfuse-worker`. The overlay does this. |
| **CH schema ≠ API** | Query ClickHouse directly for labs/debugging, but treat the schema as unstable. For apps, use the Public API / SDK query helpers / Blob Storage Export. |
| **`retention=0` = forever** | Minimum non-zero retention is 3 days. Pair retention with a Blob Storage Export if you must archive before deletion. |

### 📝 Verification status

Verified **end-to-end on 2026-06-25** against **Langfuse v3.197.1** (Docker Compose, 6 containers) with a real enterprise trial license key:

| Step | Result |
|---|---|
| `01` stack up | 6 containers healthy; `/api/public/health` → `{"status":"OK","version":"3.197.1"}` |
| `02` generate traces | 40 traces ingested via the SDK (offline mode) |
| `03` explore | tables `traces` / `observations` / `scores` are `ReplacingMergeTree`, monthly-partitioned |
| `04` analytics | all 8 queries pass; cost/latency/quality numbers sane |
| `05` EE activate | Instance Management API `/api/admin/organizations` → HTTP 200 (license valid) |
| `06` RBAC/SCIM | org + project + 2 SCIM users + project-level role override, all via API |
| `07` audit/retention | 14-day retention set (`retentionDays: 14`); audit log shows every lab-06 action |

Labs **08–11 were verified end-to-end on 2026-07-26** (Langfuse v3.197.1, ClickHouse 25.11.2.24, SDK 3.7.0, Docker 29.6.2) with a real enterprise license key. Full captured console output for the whole 01→11 run is in **[lab-output.md](lab-output.md)** (blog-ready).

| Step | Result |
|---|---|
| `08` data masking | leak counts all `0` in `traces`+`observations`; **24 rows** carry `[REDACTED_*]`; sidecar logged **84 redactions** |
| `09` protected prompts | v1→v2 label move (v1 `labels={}`); prompt rows in Postgres; 2 `create prompt` audit rows |
| `10` governance | all `LANGFUSE_UI_*` + `LANGFUSE_ALLOWED_ORGANIZATION_CREATORS` confirmed in the container env |
| `11` parquet export | CH `s3()` round-trip **93 == 93**; integration API on v3.197.1 accepts `JSON/CSV/JSONL` only (not `PARQUET`) → JSONL fallback; ClickHouse writes true Parquet in Part B |

> **Version-drift finding (lab 11):** the published OpenAPI spec lists `fileType: PARQUET` for the blob-storage integration, but the pinned **v3.197.1** image rejects it with HTTP 400 (`JSON`/`CSV`/`JSONL` only) — scheduled-Parquet export is a newer release. Validate the API surface against your *running* image, not just the docs. The lab script tries `PARQUET`, then falls back to `JSONL`.
>
> **Portability note (lab 08):** the driver auto-detects the Python interpreter (prefers `.venv/bin/python`, falls back to `python3`), so it runs on macOS where bare `python` doesn't exist.

Two things confirmed at runtime and baked into the labs: **(1)** Langfuse tables are `ReplacingMergeTree`, so analytics read with `FINAL` + `WHERE is_deleted = 0` to avoid double-counting un-merged row versions; **(2)** the SDK's `input_tokens`/`output_tokens` are normalized to the Map keys `input`/`output`/`total` in ClickHouse (the queries use `greatest()` over both spellings). The ClickHouse `DESCRIBE` output in lab 03 is authoritative for your installed version.

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
- [Python SDK](https://langfuse.com/docs/observability/sdk/overview)

### 📝 License

MIT License

### 👤 Author

Ken Lee (ClickHouse Solution Architect) — ken.lee@clickhouse.com
Created: 2026-06-25 · EE track (labs 08–11) added: 2026-07-26

---

**Happy Tracing! 🔭**

For questions, see the main [clickhouse-hols README](../../README.md).

---

## 한국어

**[Langfuse](https://langfuse.com) self-hosting** — 오픈소스 LLM 관측가능성(observability) 플랫폼 — 을 직접 구축하고, 그 내부를 떠받치는 **ClickHouse 백엔드**까지 들여다보는 종단간 실습입니다.

Langfuse v3는 OLTP 상태(사용자·조직·프로젝트·프롬프트·감사 로그)를 **Postgres**에 저장하지만, 모든 **trace·observation·score**는 **ClickHouse**에 적재됩니다. 즉 Langfuse는 몇 분 만에 띄울 수 있는 실전급 ClickHouse 애플리케이션이며, 고볼륨 append-only LLM 텔레메트리에 왜 ClickHouse가 적합한지를 직접 체감하기에 좋은 사례입니다.

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
      │ users,   │      │ traces,    │       │ 캐시    │     │ 원본이벤트│
      │ orgs,    │      │ observations│      └─────────┘     │ 미디어,   │
      │ audit_log│      │ scores     │ ◄── 랩 03 & 04        │ 익스포트  │
      └──────────┘      └────────────┘                      └──────────┘
```

### 📁 파일 구조

```
langfuse-ee/
├── README.md                    # 이 문서
├── .env.example                 # 시크릿, headless-init, EE 라이선스 키, SDK 키
├── docker-compose.yml           # OSS 스택: web · worker · postgres · clickhouse · redis · minio
├── docker-compose.ee.yml        # EE 오버레이: 라이선스 키 + admin API 키 주입
├── docker-compose.masking.yml   # 랩 08 오버레이: 마스킹 사이드카 + worker 콜백 연결
├── docker-compose.governance.yml# 랩 10 오버레이: UI 커스터마이징 + 조직 생성 허용목록
├── 01-up.sh                     # 스택 기동, 헬스 대기, 자격증명 출력
├── 02-generate-traces.py        # Python SDK v3+: 중첩 span/generation, 세션, 스코어
├── 03-clickhouse-explore.sql    # ClickHouse의 traces/observations/scores 테이블 탐색
├── 04-clickhouse-analytics.sql  # ClickHouse에서 직접 비용/지연/품질 분석
├── 05-ee-activate.sh            # 라이선스 키로 재기동, EE 활성화 검증
├── 06-ee-rbac-scim.sh           # 조직/프로젝트 프로비저닝, SCIM 사용자, 프로젝트 단위 RBAC
├── 07-ee-audit-retention.sh     # 데이터 보존 정책 + 감사 로그 조회
├── 08-ee-data-masking.sh        # 서버측 마스킹 → ClickHouse에서 부재 증명
│   ├── masking_service.py       #   ↳ stdlib 전용 초경량 마스킹 콜백 사이드카
│   ├── 08-generate-pii-traces.py#   ↳ 센티넬 시크릿/PII가 든 trace 전송
│   └── 08-verify-masking.sql    #   ↳ ClickHouse 증명: 원문 시크릿 부재, [REDACTED_*] 존재
├── 09-ee-protected-prompts.sh   # 버전 관리 프롬프트 + 배포 라벨 + 보호된 라벨
├── 10-ee-instance-governance.sh # UI 커스터마이징 + 조직 생성 허용목록
├── 11-ee-parquet-export.sh      # Blob 스토리지 Parquet 반출 + ClickHouse s3() 라운드트립
└── 99-cleanup.sh                # 스택 종료 (--purge 로 볼륨까지 삭제)
```

### ✅ 사전 준비물

- **Docker + Docker Compose** (Mac/Windows는 Docker Desktop). CPU 4코어 / 16 GiB 이상 권장.
- 랩 02용 **Python 3.9+**.
- 엔터프라이즈 스크립트(05–07)용 **`jq`** 와 **`curl`**.
- 랩 05–07용 **엔터프라이즈 라이선스 키** (OSS 트랙은 추가 준비물 없음).

### 🚀 빠른 시작 (OSS 트랙)

```bash
cd usecase/langfuse-ee
cp .env.example .env            # 로컬 외 용도면 # CHANGEME 시크릿을 수정

# 1) 배포. 첫 기동 시 Postgres + ClickHouse 마이그레이션 (~2-3분)
./01-up.sh
#    → http://localhost:3000  (로그인: admin@example.com / workshop-admin-pw)

# 2) 현실적인 trace 약 40건 적재 (완전 오프라인; LLM 키 불필요)
python -m venv .venv && source .venv/bin/activate
pip install "langfuse>=3" openai
python 02-generate-traces.py

# 3) Langfuse의 ClickHouse 백엔드 탐색
docker compose exec -T clickhouse clickhouse-client -u clickhouse --password clickhouse \
  --multiquery < 03-clickhouse-explore.sql

# 4) ClickHouse에서 직접 LLM 관측 분석 실행
docker compose exec -T clickhouse clickhouse-client -u clickhouse --password clickhouse \
  --multiquery < 04-clickhouse-analytics.sql
```

### 🏢 Enterprise 트랙

```bash
# .env 에 키 입력:   LANGFUSE_EE_LICENSE_KEY=<발급받은 키>
#                    ADMIN_API_KEY=<임의의 강한 랜덤 문자열>

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

[docker-compose.yml](docker-compose.yml)의 6개 컨테이너를 띄우고 `GET /api/public/health`가 OK를 반환할 때까지 대기합니다. compose 파일은 **headless 초기화**(`.env`의 `LANGFUSE_INIT_*`)로 최초 조직·프로젝트·사용자·API 키를 부팅 시 자동 생성하므로, 데이터 전송 전 **UI 클릭 작업이 전혀 필요 없습니다**. 주목할 점: ClickHouse는 단일 노드(`CLICKHOUSE_CLUSTER_ENABLED=false`), 모든 백엔드는 **UTC**(Langfuse 필수 요건), MinIO가 S3 호환 blob 스토리지를 제공.

#### 02 — Trace 생성

**Langfuse Python SDK (v3+, OpenTelemetry 네이티브)** 로 고객 지원 RAG 어시스턴트를 시뮬레이션합니다. 각 trace는 중첩 observation 트리입니다.

```python
with lf.start_as_current_observation(as_type="span", name="support-request") as root:
    lf.update_current_trace(user_id=..., session_id=..., tags=[...])     # trace 메타데이터
    with lf.start_as_current_observation(as_type="span", name="retrieve-context"): ...
    with lf.start_as_current_observation(as_type="generation",
                                         name="answer-generation", model="gpt-4o") as gen:
        gen.update(output=..., usage_details={"input_tokens": ..., "output_tokens": ...})
lf.create_score(name="user-thumbs", value=1, data_type="BOOLEAN", trace_id=...)
lf.flush()   # 짧은 스크립트에서 필수 — 종료 전 비동기 버퍼 전송
```

모델·사용자·세션·태그(`env`/`feature`/`tier`)·토큰 사용량·지연·오류(~8%)를 다양화하고 스코어를 부착합니다. 비용은 모델명 + 토큰 사용량으로부터 Langfuse가 **자동 계산**합니다. 기본은 오프라인이며, `OPENAI_API_KEY`를 설정하면 drop-in `from langfuse.openai import openai`로 실제 호출합니다.

#### 03 — ClickHouse 백엔드 탐색

Langfuse가 마이그레이션한 `default` 데이터베이스에 대한 순수 탐색: `SHOW TABLES`, `DESCRIBE traces/observations/scores`, 엔진 + 정렬 키 + 파티셔닝, 행 수, 한 trace의 전체 observation 트리, 월별 파티션 레이아웃. **trace는 `traces`의 한 행이고, 그 단계들은 `trace_id`로 연결된 `observations`의 행이며, 스코어는 `scores`에 저장됩니다.**

> ClickHouse 스키마는 Langfuse 내부 구현 세부사항이며 **안정적인 API가 아닙니다** — 메이저 버전 간 컬럼명이 바뀔 수 있습니다. 설치된 버전의 정답은 항상 `DESCRIBE` 출력입니다.

#### 04 — ClickHouse 분석

SA 관점의 핵심: Langfuse UI가 답하는 질문들을 순수 ClickHouse SQL로 표현하고, 이 워크로드에 ClickHouse가 왜 맞는지 보여줍니다.

| 쿼리 | ClickHouse 기능 |
|---|---|
| 모델별 비용·토큰 | `Map` 컬럼(`usage_details`, `cost_details`)에 대한 `sum()` |
| 모델별 지연 p50/p95/p99 | `dateDiff('millisecond', …)`에 대한 `quantile()` |
| 모델별 오류율 | `countIf(level = 'ERROR')` 조건부 집계 |
| 고객 등급별 비용·품질 | `tags`에 대한 `arrayFirst()` + observation JOIN |
| 추천(thumbs-up)율 / 그라운딩 | `scores` 테이블의 `sumIf`/`avgIf` |
| 사용자별 비용 리더보드 | trace ↔ observation JOIN, 비용 귀속 |
| 일별 추이 / 세션 깊이 | 시간 버킷팅 + `uniqExact` |

#### 05 — Enterprise 활성화

[docker-compose.ee.yml](docker-compose.ee.yml)로 `langfuse-web` + `langfuse-worker`를 재배포하여 `LANGFUSE_EE_LICENSE_KEY`를 **양쪽** 컨테이너에 주입합니다(+ `ADMIN_API_KEY`). 유효한 라이선스가 있을 때만 응답하는 **Instance Management API**(`/api/admin/organizations`)로 활성화를 검증합니다.

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

**ClickHouse로 검증 가능한** 핵심 EE 데모입니다. 초경량 마스킹 콜백 사이드카([masking_service.py](masking_service.py), stdlib 전용)를 [docker-compose.masking.yml](docker-compose.masking.yml)로 worker의 `LANGFUSE_INGESTION_MASKING_CALLBACK_URL`에 연결합니다. Langfuse는 OTLP로 인제스트된 각 trace를 콜백에 POST하고, 콜백은 시크릿/PII 패턴(API 키, 신용카드, 이메일, 주민등록번호)을 리댁션한 뒤 동일 구조로 반환합니다 — **저장 이전에** 일어납니다.

[08-generate-pii-traces.py](08-generate-pii-traces.py)가 4개 센티넬 시크릿이 든 trace를 보내고, [08-verify-masking.sql](08-verify-masking.sql)이 **ClickHouse에서 직접** 결과를 증명합니다:

```sql
-- 전부 0이어야 함: 원문 시크릿이 OLAP 스토어에 도달하지 않음
countIf(position(toString(input), '0xDEADBEEF01') > 0 OR position(toString(output), '0xDEADBEEF01') > 0)  AS leaked_api_key
-- 0보다 커야 함: 리댁션 placeholder는 안착
countIf(position(toString(input), '[REDACTED_') > 0)  AS masked_observation_rows
```

핵심: 마스킹은 **OTLP 엔드포인트**(`/api/public/otel` = SDK v3+)에만 적용; `FAIL_CLOSED=true`면 콜백 오류 시 이벤트를 드롭(보안 기본값); 콜백 본문은 **OTLP Trace Request proto(JSON)** 이므로 사이드카는 JSON을 딥워크하며 문자열 리프만 재작성합니다.

#### 09 — 보호된 프롬프트 라벨 ([09-ee-protected-prompts.sh](09-ee-protected-prompts.sh))

프롬프트 거버넌스. 버전 관리 프롬프트를 생성하고 `production` 라벨을 v1 → v2로 API로 이동, 현재 production 프롬프트를 조회한 뒤, 그 버전들이 **Postgres**에 저장됨(프롬프트는 OLTP — ClickHouse 아님)과 **감사 로그**의 대응 행(랩 07과 연결)을 보여줍니다. 마무리는 EE **보호된 라벨**: Project Settings에서 `production`을 보호로 지정하면 랩 06의 역할이 적용되어 Bob(`VIEWER`)·Alice(`MEMBER`)는 라벨을 재지정/삭제할 수 없고 Owner/Admin만 가능합니다. 보호 토글은 UI 전용(공개 API 없음)이며, 강제는 사용자 역할 기준입니다.

#### 10 — 인스턴스 거버넌스 ([10-ee-instance-governance.sh](10-ee-instance-governance.sh))

두 가지 인스턴스 레벨 제어를 [docker-compose.governance.yml](docker-compose.governance.yml)로 env 주입: **UI 커스터마이징**(`LANGFUSE_UI_LOGO_*`, `LANGFUSE_UI_FEEDBACK/DOCUMENTATION/SUPPORT_HREF` — 코브랜딩 + 도움말 링크 내부화)과 **조직 생성 허용목록**(`LANGFUSE_ALLOWED_ORGANIZATION_CREATORS` — 목록의 이메일만 새 조직 생성 가능). 스크립트는 `langfuse-web`를 재배포한 뒤 실행 중 컨테이너에 `exec … env | grep`으로 **변수가 실제 주입되었음을 증명**하고, UI 검증 체크리스트를 출력합니다.

#### 11 — Parquet 반출 ↔ ClickHouse ([11-ee-parquet-export.sh](11-ee-parquet-export.sh))

엔터프라이즈 데이터플랫폼/아카이브 스토리를 두 파트로. **(A)** `PUT /api/public/integrations/blob-storage`로 스케줄 **Parquet** blob 스토리지 반출 설정(type `S3_COMPATIBLE`, 워크숍 MinIO 지정). **(B)** 그것을 구동하는 바로 그 primitive를 ClickHouse로 **라이브** 시연 — 스케줄러를 기다리지 않음:

```sql
INSERT INTO FUNCTION s3('http://minio:9000/langfuse/exports/manual/traces.parquet',
                        'minio', 'miniosecret', 'Parquet')
  SELECT * FROM default.traces FINAL WHERE is_deleted = 0 SETTINGS s3_truncate_on_insert = 1;
SELECT count() FROM s3('http://minio:9000/langfuse/exports/manual/traces.parquet',
                       'minio', 'miniosecret', 'Parquet');   -- 곧바로 다시 읽기
```

랩 07과 **archive-then-delete**로 짝을 이룸: 보존 삭제 전에 반출. SA 함정 반영 — self-hosted에서 **ClickHouse < 25.11**은 Parquet 반출 실패가 안 뜰 수 있음(불완전 파일인데 "성공"). ≥ 25.11로 업그레이드하거나 신뢰할 수 있는 실패 감지를 위해 CSV/JSON 사용.

### 🔑 기억할 함정들

| | 노트 |
|---|---|
| **두 DB, 두 역할** | Postgres = OLTP(사용자·조직·프롬프트·**감사 로그**). ClickHouse = OLAP(**traces·observations·scores**). Postgres에서 trace를 찾지 말 것. |
| **모든 곳에서 UTC** | ClickHouse **와** Postgres 모두 UTC여야 함. 아니면 쿼리가 틀리거나 빈 결과를 반환. compose가 설정함. |
| **스크립트에서 `flush()`** | SDK는 비동기 전송. `lf.flush()` 없이 종료하는 짧은 스크립트는 trace를 잃음. |
| **비용은 파생값** | `usage_details`(토큰)를 보내면 Langfuse가 모델 가격표로 비용 계산. 알려진 모델명 사용(`gpt-4o`, `claude-3-5-sonnet-…`). |
| **EE 라이선스는 양쪽 컨테이너에** | `LANGFUSE_EE_LICENSE_KEY`는 `langfuse-web`과 `langfuse-worker` 모두에 필요. 오버레이가 처리. |
| **CH 스키마 ≠ API** | 랩/디버깅용으로 ClickHouse를 직접 조회하되 스키마는 불안정하다고 간주. 앱에서는 Public API / SDK query helper / Blob Storage Export 사용. |
| **`retention=0` = 영구** | 0이 아닌 최소 보존은 3일. 삭제 전 보관이 필요하면 Blob Storage Export와 병행. |

### 📝 검증 상태

**2026-06-25**에 실제 엔터프라이즈 트라이얼 라이선스 키로 **Langfuse v3.197.1**(Docker Compose, 컨테이너 6개)에서 **end-to-end 검증**했습니다.

| 단계 | 결과 |
|---|---|
| `01` 스택 기동 | 컨테이너 6개 healthy; `/api/public/health` → `{"status":"OK","version":"3.197.1"}` |
| `02` 트레이스 생성 | SDK(오프라인 모드)로 40건 적재 |
| `03` 탐색 | `traces`/`observations`/`scores`는 `ReplacingMergeTree`, 월별 파티션 |
| `04` 분석 | 8개 쿼리 전부 통과; 비용/지연/품질 수치 타당 |
| `05` EE 활성화 | Instance Management API `/api/admin/organizations` → HTTP 200 (라이선스 유효) |
| `06` RBAC/SCIM | 조직 + 프로젝트 + SCIM 사용자 2명 + 프로젝트 단위 역할 오버라이드, 전부 API로 |
| `07` 감사/보존 | 14일 보존 설정(`retentionDays: 14`); 감사 로그에 lab 06의 모든 동작 기록됨 |

랩 **08–11은 2026-07-26에 end-to-end 검증**했습니다(Langfuse v3.197.1, ClickHouse 25.11.2.24, SDK 3.7.0, Docker 29.6.2, 실제 엔터프라이즈 라이선스 키). 01→11 전체 실행의 콘솔 출력 원본은 **[lab-output.md](lab-output.md)** 에 있습니다(블로그용).

| 단계 | 결과 |
|---|---|
| `08` 데이터 마스킹 | `traces`+`observations` leak 카운트 전부 `0`; **24행**에 `[REDACTED_*]`; 사이드카 로그 **84 redactions** |
| `09` 보호된 프롬프트 | v1→v2 라벨 이동(v1 `labels={}`); 프롬프트 행 Postgres에; `create prompt` 감사 2건 |
| `10` 거버넌스 | 컨테이너 env에 `LANGFUSE_UI_*` + `LANGFUSE_ALLOWED_ORGANIZATION_CREATORS` 전부 확인 |
| `11` parquet 반출 | CH `s3()` 라운드트립 **93 == 93**; v3.197.1 통합 API는 `JSON/CSV/JSONL`만 허용(`PARQUET` 미지원) → JSONL 폴백; Part B에서 ClickHouse가 진짜 Parquet 기록 |

> **버전 드리프트 발견(랩 11):** 공개 OpenAPI 스펙엔 blob-storage 통합의 `fileType: PARQUET`가 있으나 고정 이미지 **v3.197.1**은 HTTP 400으로 거부(`JSON`/`CSV`/`JSONL`만) — 스케줄 Parquet 반출은 더 최신 릴리스. 문서가 아니라 *실행 중인 이미지* 기준으로 API를 검증할 것. 스크립트는 `PARQUET` 시도 후 `JSONL`로 폴백.
>
> **이식성 노트(랩 08):** 드라이버가 Python 인터프리터를 자동 감지(`.venv/bin/python` 우선, `python3` 폴백)하므로 bare `python`이 없는 macOS에서도 실행됩니다.

런타임에서 확인해 랩에 반영한 두 가지: **(1)** Langfuse 테이블은 `ReplacingMergeTree`이므로, 병합 전 중복 버전을 이중 집계하지 않도록 분석 쿼리는 `FINAL` + `WHERE is_deleted = 0`으로 읽습니다. **(2)** SDK의 `input_tokens`/`output_tokens`는 ClickHouse에서 Map 키 `input`/`output`/`total`로 정규화됩니다(쿼리는 두 표기를 `greatest()`로 처리). 설치 버전의 정답은 랩 03의 `DESCRIBE` 출력입니다.

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
- [Python SDK](https://langfuse.com/docs/observability/sdk/overview)

### 📝 라이선스

MIT License

### 👤 작성자

Ken Lee (ClickHouse Solution Architect) — ken.lee@clickhouse.com
작성일: 2026-06-25 · EE 트랙(랩 08–11) 추가: 2026-07-26

---

**Happy Tracing! 🔭**

질문이나 이슈는 메인 [clickhouse-hols README](../../README.md)를 참조하세요.
