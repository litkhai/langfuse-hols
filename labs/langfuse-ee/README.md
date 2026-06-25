# Self-Hosting Langfuse on ClickHouse — Workshop (OSS + Enterprise)

[English](#english) | [한국어](#한국어)

---

## English

A hands-on, end-to-end workshop for **self-hosting [Langfuse](https://langfuse.com)** — the open-source LLM observability platform — and then looking *under the hood* at the **ClickHouse backend** that powers it.

Langfuse v3 stores all of its OLTP state (users, orgs, projects, prompts, the audit log) in **Postgres**, but every **trace, observation, and score** lands in **ClickHouse**. That makes Langfuse a real, production-grade ClickHouse application you can stand up in minutes — and a great way to *feel* why ClickHouse is the right OLAP engine for high-volume, append-only LLM telemetry.

The workshop has two tracks:

- **OSS track (labs 01–04)** — deploy the full stack with Docker Compose, push realistic traces with the Python SDK, then query the ClickHouse backend directly with SQL.
- **Enterprise track (labs 05–07)** — activate an **enterprise license key** and exercise the EE-only features: project-level **RBAC**, **SCIM** provisioning, the **Instance Management / Org API**, **Audit Logs**, and **Data Retention** policies.

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
langfuse/
├── README.md                  # This file
├── .env.example               # Secrets, headless-init, EE license key, SDK keys
├── docker-compose.yml         # OSS stack: web · worker · postgres · clickhouse · redis · minio
├── docker-compose.ee.yml      # EE overlay: injects license key + admin API key
├── 01-up.sh                   # Bring the stack up, wait for health, print credentials
├── 02-generate-traces.py      # Python SDK v3+: nested spans/generations, sessions, scores
├── 03-clickhouse-explore.sql  # Discover the traces/observations/scores tables in ClickHouse
├── 04-clickhouse-analytics.sql# Cost / latency / quality analytics straight on ClickHouse
├── 05-ee-activate.sh          # Restart with the license key, verify EE is active
├── 06-ee-rbac-scim.sh         # Org/project provisioning, SCIM users, project-level RBAC
├── 07-ee-audit-retention.sh   # Data-retention policy + read the audit log
└── 99-cleanup.sh              # Tear the stack down (--purge to wipe volumes)
```

### ✅ Prerequisites

- **Docker + Docker Compose** (Docker Desktop on Mac/Windows). Give it ≥ 4 CPU / 16 GiB.
- **Python 3.9+** for lab 02.
- **`jq`** and **`curl`** for the enterprise scripts (05–07).
- An **enterprise license key** for labs 05–07 (the OSS track needs nothing extra).

### 🚀 Quick Start (OSS track)

```bash
cd usecase/langfuse
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

./05-ee-activate.sh        # redeploy with the EE overlay; verify license is active
./06-ee-rbac-scim.sh       # create org → org key → project → SCIM users → RBAC roles
./07-ee-audit-retention.sh # set a 14-day retention policy + dump the audit log
```

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

The Docker Compose stack and `.env` are derived 1:1 from the upstream Langfuse v3 [`docker-compose.yml`](https://github.com/langfuse/langfuse/blob/main/docker-compose.yml) and self-hosting docs (fetched 2026-06-25). The Python SDK calls follow the v3/v4 (OpenTelemetry-native) API, and the enterprise scripts follow the documented Instance Management, Org/SCIM, and projects APIs. Because the full stack requires Docker images + license key at runtime, run the labs in order; the ClickHouse `DESCRIBE` output in lab 03 is authoritative for your installed version.

### 🔍 Additional resources

- [Self-host Langfuse — overview](https://langfuse.com/self-hosting)
- [Docker Compose deployment](https://langfuse.com/self-hosting/deployment/docker-compose)
- [ClickHouse for Langfuse](https://langfuse.com/self-hosting/deployment/infrastructure/clickhouse)
- [Enterprise License Key](https://langfuse.com/self-hosting/license-key)
- [Access Control (RBAC)](https://langfuse.com/docs/administration/rbac) · [SCIM & Org API](https://langfuse.com/docs/administration/scim-and-org-api)
- [Audit Logs](https://langfuse.com/docs/administration/audit-logs) · [Data Retention](https://langfuse.com/docs/administration/data-retention)
- [Python SDK](https://langfuse.com/docs/observability/sdk/overview)

### 📝 License

MIT License

### 👤 Author

Ken Lee (ClickHouse Solution Architect) — ken.lee@clickhouse.com
Created: 2026-06-25

---

**Happy Tracing! 🔭**

For questions, see the main [clickhouse-hols README](../../README.md).

---

## 한국어

**[Langfuse](https://langfuse.com) self-hosting** — 오픈소스 LLM 관측가능성(observability) 플랫폼 — 을 직접 구축하고, 그 내부를 떠받치는 **ClickHouse 백엔드**까지 들여다보는 종단간 실습입니다.

Langfuse v3는 OLTP 상태(사용자·조직·프로젝트·프롬프트·감사 로그)를 **Postgres**에 저장하지만, 모든 **trace·observation·score**는 **ClickHouse**에 적재됩니다. 즉 Langfuse는 몇 분 만에 띄울 수 있는 실전급 ClickHouse 애플리케이션이며, 고볼륨 append-only LLM 텔레메트리에 왜 ClickHouse가 적합한지를 직접 체감하기에 좋은 사례입니다.

실습은 두 트랙으로 구성됩니다.

- **OSS 트랙 (랩 01–04)** — Docker Compose로 전체 스택 배포 → Python SDK로 현실적인 trace 적재 → ClickHouse 백엔드를 SQL로 직접 조회.
- **Enterprise 트랙 (랩 05–07)** — **엔터프라이즈 라이선스 키**를 활성화하고 EE 전용 기능을 실습: 프로젝트 단위 **RBAC**, **SCIM** 프로비저닝, **Instance Management / Org API**, **감사 로그(Audit Logs)**, **데이터 보존(Data Retention)** 정책.

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
langfuse/
├── README.md                  # 이 문서
├── .env.example               # 시크릿, headless-init, EE 라이선스 키, SDK 키
├── docker-compose.yml         # OSS 스택: web · worker · postgres · clickhouse · redis · minio
├── docker-compose.ee.yml      # EE 오버레이: 라이선스 키 + admin API 키 주입
├── 01-up.sh                   # 스택 기동, 헬스 대기, 자격증명 출력
├── 02-generate-traces.py      # Python SDK v3+: 중첩 span/generation, 세션, 스코어
├── 03-clickhouse-explore.sql  # ClickHouse의 traces/observations/scores 테이블 탐색
├── 04-clickhouse-analytics.sql# ClickHouse에서 직접 비용/지연/품질 분석
├── 05-ee-activate.sh          # 라이선스 키로 재기동, EE 활성화 검증
├── 06-ee-rbac-scim.sh         # 조직/프로젝트 프로비저닝, SCIM 사용자, 프로젝트 단위 RBAC
├── 07-ee-audit-retention.sh   # 데이터 보존 정책 + 감사 로그 조회
└── 99-cleanup.sh              # 스택 종료 (--purge 로 볼륨까지 삭제)
```

### ✅ 사전 준비물

- **Docker + Docker Compose** (Mac/Windows는 Docker Desktop). CPU 4코어 / 16 GiB 이상 권장.
- 랩 02용 **Python 3.9+**.
- 엔터프라이즈 스크립트(05–07)용 **`jq`** 와 **`curl`**.
- 랩 05–07용 **엔터프라이즈 라이선스 키** (OSS 트랙은 추가 준비물 없음).

### 🚀 빠른 시작 (OSS 트랙)

```bash
cd usecase/langfuse
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

./05-ee-activate.sh        # EE 오버레이로 재배포; 라이선스 활성 검증
./06-ee-rbac-scim.sh       # 조직 → 조직 키 → 프로젝트 → SCIM 사용자 → RBAC 역할
./07-ee-audit-retention.sh # 14일 보존 정책 설정 + 감사 로그 덤프
```

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

Docker Compose 스택과 `.env`는 업스트림 Langfuse v3 [`docker-compose.yml`](https://github.com/langfuse/langfuse/blob/main/docker-compose.yml) 및 self-hosting 문서(2026-06-25 기준)에서 1:1로 도출했습니다. Python SDK 호출은 v3/v4(OpenTelemetry 네이티브) API를, 엔터프라이즈 스크립트는 문서화된 Instance Management·Org/SCIM·projects API를 따릅니다. 전체 스택은 런타임에 Docker 이미지 + 라이선스 키가 필요하므로 랩을 순서대로 실행하세요. 랩 03의 ClickHouse `DESCRIBE` 출력이 설치 버전의 정답입니다.

### 🔍 추가 자료

- [Self-host Langfuse — 개요](https://langfuse.com/self-hosting)
- [Docker Compose 배포](https://langfuse.com/self-hosting/deployment/docker-compose)
- [Langfuse용 ClickHouse](https://langfuse.com/self-hosting/deployment/infrastructure/clickhouse)
- [Enterprise License Key](https://langfuse.com/self-hosting/license-key)
- [Access Control (RBAC)](https://langfuse.com/docs/administration/rbac) · [SCIM & Org API](https://langfuse.com/docs/administration/scim-and-org-api)
- [Audit Logs](https://langfuse.com/docs/administration/audit-logs) · [Data Retention](https://langfuse.com/docs/administration/data-retention)
- [Python SDK](https://langfuse.com/docs/observability/sdk/overview)

### 📝 라이선스

MIT License

### 👤 작성자

Ken Lee (ClickHouse Solution Architect) — ken.lee@clickhouse.com
작성일: 2026-06-25

---

**Happy Tracing! 🔭**

질문이나 이슈는 메인 [clickhouse-hols README](../../README.md)를 참조하세요.
