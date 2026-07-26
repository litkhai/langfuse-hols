# Langfuse-on-ClickHouse Enterprise Workshop — Full Run Log & Blog Source

A complete, captured end-to-end run of every lab in [`usecase/langfuse-ee/`](./README.md) — OSS track (01–04) and the full Enterprise track (05–11). This is the raw material for a tech blog: real commands, real output, and the findings that surfaced while running it.

> Language note: the run log below is English (the console output is language-neutral). A ready-to-use **Korean blog outline (한국어 블로그 아웃라인)** is at the end.

---

## TL;DR

- Self-hosted **Langfuse v3.197.1** stores every trace/observation/score in **ClickHouse 25.11.2.24**. We stood the stack up, pushed traces with the Python SDK, and ran cost/latency/quality analytics straight on ClickHouse.
- Then we activated an **Enterprise license** and exercised **9 EE entitlements** end-to-end — the highlight being **server-side data masking, *proven* absent in ClickHouse with SQL**, and a **Parquet export ↔ ClickHouse `s3()` round-trip**.
- Everything ran on a laptop in ~25 minutes. Five findings worth a blog section came out of the run (masking proof, RMT dedup, prompt-label movement, an **OpenAPI-vs-pinned-image version drift**, and object-storage archival).

## Environment

| Component | Version / detail |
|---|---|
| Host | macOS (Darwin 25.5), Docker Desktop |
| Docker Engine | 29.6.2 |
| Docker Compose | v5.3.1 |
| Langfuse (web + worker) | **v3.197.1** (`langfuse/langfuse:3`, `langfuse/langfuse-worker:3`) |
| ClickHouse | **25.11.2.24** |
| Postgres / Redis / MinIO | 17 / 7 / chainguard-minio |
| Masking sidecar | `python:3.12-slim` (stdlib only) |
| Python SDK | `langfuse` **3.7.0** (OpenTelemetry-native) |
| Run date | 2026-07-26 |

## Run summary

| Lab | Feature | Result |
|---|---|---|
| 01 | Stack up (6 containers) | ✅ healthy; `/api/public/health` → `{"status":"OK","version":"3.197.1"}` |
| 02 | Generate traces (SDK) | ✅ 40 traces ingested (offline mode) |
| 03 | Explore CH backend | ✅ `traces`/`observations`/`scores` = `ReplacingMergeTree`, monthly partitions |
| 04 | Analytics on CH | ✅ 8 queries — cost/latency p95/quality/leaderboard |
| 05 | Activate Enterprise | ✅ Instance Management API → HTTP 200 |
| 06 | RBAC & SCIM | ✅ org + project + 2 SCIM users + project-level role override |
| 07 | Data retention + audit | ✅ 14-day retention; audit log shows every lab-06 action |
| 08 | **Server-side data masking** | ✅ **leak counts = 0 in ClickHouse; 24 rows redacted; 84 redactions** |
| 09 | Protected prompt labels | ✅ v1→v2 label move; prompts in Postgres; audited |
| 10 | Instance governance | ✅ UI + org-creator vars injected & verified |
| 11 | Parquet export ↔ CH | ✅ CH `s3()` round-trip **93 == 93**; integration API version-drift documented |

---

## Reset — clean slate

```console
$ ./99-cleanup.sh --purge
▶ Stopping stack and DELETING all data volumes…
 …
 Volume langfuse-ee_langfuse_clickhouse_data Removed
 Volume langfuse-ee_langfuse_postgres_data  Removed
 Volume langfuse-ee_langfuse_minio_data     Removed
 …
✅ Stack down, volumes removed.
```

## Lab 01 — Deploy the stack (OSS)

```console
$ ./01-up.sh
▶ Starting Langfuse stack in OSS mode (postgres · clickhouse · redis · minio · web · worker)…
 …
 Container langfuse-ee-langfuse-web-1 Started
▶ Waiting for langfuse-web to become healthy (first boot runs DB + ClickHouse migrations, ~2-3 min)…
.✅ Langfuse is up after ~10s.

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
$ curl -fsS http://localhost:3000/api/public/health
{"status":"OK","version":"3.197.1"}
```

The compose file uses **headless initialization** (`LANGFUSE_INIT_*`) to auto-create the first org/project/user/API-keys on boot — no UI click-ops before you can send data. On a warm image cache the stack was healthy in ~10s.

## Lab 02 — Generate traces via the Python SDK

```console
$ python 02-generate-traces.py
✓ Connected. Generating 40 traces (offline / simulated)…
  …10/40 traces
  …20/40 traces
  …30/40 traces
  …40/40 traces
✓ Done. Open http://localhost:3000 → Tracing → Traces.
```

Each trace is a nested observation tree (`support-request` span → `retrieve-context` span → `answer-generation` generation → occasional `self-check`), with per-trace scores. Runs fully offline; cost is derived by Langfuse from model name + token usage.

## Lab 03 — Explore the ClickHouse backend

```console
$ docker compose exec -T clickhouse clickhouse-client -u clickhouse --password clickhouse \
    --multiquery < 03-clickhouse-explore.sql
```

Tables Langfuse created (note the `*MergeTree` engines):

```
analytics_observations  View
analytics_scores        View
analytics_traces        View
blob_storage_file_log   ReplacingMergeTree
dataset_run_items       ReplacingMergeTree
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
traces        41
observations 130
scores        76

raw_rows   deduped_active
   41            40          -- FINAL + WHERE is_deleted = 0 gives the truth
```

Selected columns confirm `input`/`output` are `Nullable(String)` (ZSTD-compressed), `usage_details`/`cost_details` are `Map(...)`, and everything carries `event_ts` / `is_deleted` for RMT versioning + soft-deletes.

## Lab 04 — Analytics directly on ClickHouse

```console
$ docker compose exec -T clickhouse clickhouse-client -u clickhouse --password clickhouse \
    --multiquery < 04-clickhouse-analytics.sql
```

**1) Spend & tokens by model** — `sum()` over `Map` columns:

| model | calls | input_tok | output_tok | total_cost_usd | avg_cost/call |
|---|--:|--:|--:|--:|--:|
| claude-3-5-sonnet-20241022 | 10 | 9,311 | 3,292 | 0.077313 | 0.007731 |
| gpt-4o | 15 | 10,795 | 3,171 | 0.058698 | 0.003913 |
| gpt-4o-mini | 25 | 12,456 | 2,827 | 0.003565 | 0.000143 |

**2) Latency p50/p95/p99 per model** — `quantile()` over `dateDiff`:

| model | calls | avg_ms | p50 | p95 | p99 |
|---|--:|--:|--:|--:|--:|
| claude-3-5-sonnet-20241022 | 10 | 1,170 | 1,104 | 1,599.55 | 1,628.71 |
| gpt-4o | 15 | 979 | 1,046 | 1,444.30 | 1,512.06 |
| gpt-4o-mini | 25 | 276 | 220 | 559.40 | 561.00 |

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
| pro | 13 | 0.041140 | 0.003165 |

**5) Satisfaction from scores** — `sumIf`/`avgIf`: thumbs votes **40**, thumbs-up **75%**, avg grounding **0.788**.

**6) Per-user spend leaderboard** (top rows): `user_005` 4 sessions / 4 req / $0.0303 · `user_003` 5 / 6 / $0.0222 · `user_008` 4 / 4 / $0.0153 …

**7) Daily trend**: `2026-07-26` → 40 traces, 12 unique users, $0.139575.

**8) Session depth**: 26 sessions with 1 turn, 7 sessions with 2 turns.

---

## Lab 05 — Activate Enterprise

```console
$ ./05-ee-activate.sh
▶ Re-deploying with the Enterprise overlay (license key + admin API)…
 …
▶ Verifying Enterprise activation via the Instance Management API…
✅ Enterprise active. Admin API reachable. Current organizations:
{"organizations":[{"id":"ch-workshop","name":"ClickHouse Workshop","createdAt":"2026-07-26T05:18:52.128Z","metadata":{},"projects":[{"id":"llm-observability","name":"LLM Observability", …}]}]}
```

The overlay injects `LANGFUSE_EE_LICENSE_KEY` into **both** containers plus `ADMIN_API_KEY`. Proof of activation: `/api/admin/organizations` only answers HTTP 200 when a valid license is present.

## Lab 06 — RBAC & SCIM (full self-service admin chain)

```console
$ ./06-ee-rbac-scim.sh
════ 1. Create an organization (Instance Management API, Bearer auth) ════
  org id = cms1cuj4d0002tb07pupaw4ys
════ 2. Mint an organization-scoped API key ════
  org public key = pk-lf-31a2a89e-…            (secret not printed)
════ 3. Create a project under the org ════
  project id = cms1cuja20008tb07mouy4uh8
════ 4. Mint a project API key ════
  project public key = pk-lf-bc04af1f-…
════ 5. SCIM: provision two users (as an IdP like Okta/Entra would) ════
  alice id = cms1cujey…   bob id = cms1cujfo…
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
▶ Setting 14-day retention on project 'llm-observability'…
{ "id": "llm-observability", "name": "LLM Observability", "retentionDays": 14 }

════════════════ B) Audit Logs ════════════════
  table = audit_logs           (stored in Postgres, snake_case columns)
▶ Most recent audit events:
       created_at        | action | resource_type |          actor
-------------------------+--------+---------------+---------------------------
 2026-07-26 05:26:09.711 | create | apiKey        | ADMIN_KEY
 2026-07-26 05:26:01.958 | create | orgMembership | cms1cuj8p0005tb07v5vvlwnj
 2026-07-26 05:26:01.933 | create | orgMembership | cms1cuj8p0005tb07v5vvlwnj
 2026-07-26 05:26:01.891 | create | apiKey        | ORG_KEY
 2026-07-26 05:26:01.709 | create | apiKey        | ADMIN_KEY
 2026-07-26 05:26:01.554 | create | organization  | ADMIN_KEY
```

A non-zero retention value requires the data-retention entitlement (rejected on OSS). A nightly worker then deletes traces/observations/scores older than the window straight from ClickHouse. The audit log is the immutable who/what/when — note it captured **every action lab 06 just performed**, with before/after state.

---

## Lab 08 — Server-Side Data Masking ⭐ (proven in ClickHouse)

The flagship demo: a tiny stdlib masking-callback sidecar is wired to the worker; Langfuse POSTs each OTLP-ingested trace to it, and it redacts secrets **before** the trace is persisted. We then prove — *with SQL against ClickHouse* — that the raw secrets never landed.

```console
$ ./08-ee-data-masking.sh
▶ Bringing up the masking sidecar + wiring the worker to it…
 …
 Container langfuse-ee-masking-1 Healthy
▶ Sending PII-laden traces (secrets embedded in input/output/metadata)…
  (using interpreter: .venv/bin/python)
✓ Connected. Sending 12 PII-laden traces to the OTLP endpoint…
▶ Letting the worker ingest + mask (async)…
▶ Verifying against ClickHouse — raw secrets should be GONE, [REDACTED_*] present:
pii-demo traces present  12
── observations: raw-secret leak counts (want all 0) ──
0  0  0  0
── traces: raw-secret leak counts (want all 0) ──
0  0  0  0
── rows carrying a [REDACTED_*] placeholder (want > 0) ──
24
── sample masked observation payloads ──
Row 1: input:  … "Verify my identity, my resident number is [REDACTED_KR_RRN]."
       output: Thanks, I confirmed the resident number [REDACTED_KR_RRN] on file.
Row 2: input:  … "Our integration uses api key [REDACTED_API_KEY]; is it still valid?"
       output: The key [REDACTED_API_KEY] is active; rotate it if it was shared.
Row 3: input:  … "My card [REDACTED_CC] was charged twice, please refund."
       output: I've opened a refund for the card ending in the number you sent ([REDACTED_CC]).
```

The sidecar's own log shows the redaction count for the ingested batch:

```console
$ docker compose … logs masking
masking-1 | masking-callback listening on :3100 (POST /mask, GET /health)
masking-1 | [mask] project=llm-observability redactions=84
```

**Result:** across both `traces` and `observations`, the raw secrets (`sk-…DEADBEEF01`, `4111 1111 1111 1111`, `victim@secret-corp.test`, `900101-1234567`) return **leak count 0**, while **24 rows** carry `[REDACTED_*]`. Masking happened in-flight; ClickHouse is the source of truth that proves it. (Scope: OTLP endpoint `/api/public/otel` = SDK v3+; `FAIL_CLOSED=true` drops events if the callback errors.)

## Lab 09 — Protected Prompt Labels

```console
$ ./09-ee-protected-prompts.sh
════ 1. Create v1 … labelled 'production' ════   → {version:1, labels:[production,latest]}
════ 2. Create v2 (stricter) and MOVE 'production' ════ → {version:2, labels:[production,latest]}
════ 3. Resolve current production prompt ════
  {version:2, prompt:"You are Acme's senior support assistant. Be concise, cite the KB article id, …"}
════ 4. Prompts are OLTP → stored in POSTGRES, not ClickHouse ════
 version |       labels        |       created_at
---------+---------------------+-------------------------
       1 | {}                  | 2026-07-26 05:33:53.501
       2 | {production,latest} | 2026-07-26 05:33:53.542
════ 5. Every label change was AUDITED (ties to lab 07) ════
 create | prompt   (×2)
```

**Nice real-world detail:** after v2 takes `production`+`latest`, **v1's labels become `{}`** — deployment labels are *unique pointers that move*, not tags you accumulate. Prompts live in **Postgres** (OLTP), reinforcing the two-database model. The EE capstone (UI toggle) marks `production` **protected** so the lab-06 roles apply: Bob (`VIEWER`) / Alice (`MEMBER`) can't repoint or delete it; only Owner/Admin can.

## Lab 10 — Instance Governance (UI Customization + Org Creators)

```console
$ ./10-ee-instance-governance.sh
▶ Redeploying langfuse-web with the governance overlay…
time="…" level=warning msg="Found orphan containers (langfuse-ee-masking-1) …"
 …
▶ Proving the governance env is injected into the running container:
LANGFUSE_ALLOWED_ORGANIZATION_CREATORS=admin@example.com
LANGFUSE_UI_DOCUMENTATION_HREF=https://clickhouse.com/docs
LANGFUSE_UI_FEEDBACK_HREF=https://github.com/ClickHouse/clickhouse-hols/issues
LANGFUSE_UI_LOGO_DARK_MODE_HREF=https://clickhouse.com/favicon.ico
LANGFUSE_UI_LOGO_LIGHT_MODE_HREF=https://clickhouse.com/favicon.ico
LANGFUSE_UI_SUPPORT_HREF=https://clickhouse.com/support
✅ Governance config active.
```

Both controls are env-driven and license-gated. The script proves injection by `exec`-ing `env` inside the running container. The **orphan-container warning is expected** — lab 10's overlay set doesn't include lab 08's masking sidecar, so recreating `web`/`worker` here also drops the masking wiring (each feature overlay is independent; combine overlays if you want several active at once).

## Lab 11 — Parquet Export ↔ ClickHouse

```console
$ ./11-ee-parquet-export.sh
════════════ A) Configure a scheduled Parquet export (Langfuse Org API) ════════════
▶ PUT /api/public/integrations/blob-storage → try Parquet first…
  ⚠ HTTP 400: this Langfuse version rejected fileType=PARQUET on the integration API —
     [{"code":"invalid_value","values":["JSON","CSV","JSONL"],"path":["fileType"], …}]
  ↳ Scheduled *Parquet* blob-storage export is newer than some pinned images; the
    published OpenAPI spec can be ahead of your running version. Falling back to JSONL …
  ✅ JSONL scheduled export configured (upgrade the image to schedule Parquet):
{ "type":"S3_COMPATIBLE", "bucketName":"langfuse", "fileType":"JSONL",
  "exportFrequency":"hourly", "exportMode":"FULL_HISTORY", "enabled":true }

════════════ B) The ClickHouse primitive, live (INSERT INTO FUNCTION s3 → read back) ════════════
▶ ClickHouse version (Parquet export failures surface reliably on >= 25.11):
25.11.2.24
▶ Writing active traces to Parquet on MinIO…
▶ Reading the Parquet back from MinIO (round-trip proof):
93
▶ Schema ClickHouse inferred from the exported Parquet (first 15 columns):
    ┌─name────────┬─type─────────────────┐
 1. │ id          │ String               │
 2. │ timestamp   │ DateTime64(3, 'UTC') │
 …  │ …           │ …                    │
13. │ input       │ Nullable(String)     │
14. │ output      │ Nullable(String)     │
    └─────────────┴──────────────────────┘
```

**Round-trip integrity (verified separately):**

```console
$ clickhouse-client -q "SELECT count() FROM traces FINAL WHERE is_deleted=0;
                        SELECT count() FROM s3('…/exports/manual/traces.parquet', …, 'Parquet');"
93        -- live active traces
93        -- rows read back from the Parquet on MinIO

$ clickhouse-client -q "SELECT _path, count(), formatReadableSize(…)
                        FROM s3('…/traces.parquet', …, 'Parquet') GROUP BY _path"
langfuse/exports/manual/traces.parquet   93   4.99 KiB
```

Part B is the exact primitive Langfuse's scheduled exporter uses under the hood — `INSERT INTO FUNCTION s3(...) … 'Parquet'` then read it right back — so the ClickHouse-backed store can archive itself to object storage and stay queryable by ClickHouse, DuckDB, Athena, Spark… Pairs with lab 07 as **archive-then-delete**.

---

## Findings & gotchas (blog-worthy)

1. **Masking is provable in the warehouse, not just claimed.** With server-side masking on, a SQL scan of `traces`/`observations` for the raw secrets returns **0** while `[REDACTED_*]` placeholders are present (24 rows; sidecar logged 84 redactions). ClickHouse turns "we mask PII" into a testable assertion. Scope caveat: masking only applies to the OTLP endpoint (SDK v3+).

2. **ReplacingMergeTree: raw ≠ truth until merged.** Right after ingestion the `traces` table showed **41 raw rows → 40 deduped** (`FINAL` + `WHERE is_deleted = 0`). Every analytics query must read this way or it double-counts half-populated row versions. Sort key `project_id, toDate(timestamp), id`; partition `toYYYYMM(timestamp)`.

3. **Deployment labels *move*.** Creating prompt v2 with `production` silently cleared the label from v1 (`labels = {}`). Labels are unique pointers, which is exactly why the EE "protected label" feature exists — to stop an accidental repoint of production.

4. **The published OpenAPI spec can be ahead of your pinned image.** The blob-storage *integration* API on **v3.197.1** accepts `fileType` ∈ `{JSON, CSV, JSONL}` only — `PARQUET` returns HTTP 400, even though the cloud OpenAPI spec lists `PARQUET`. Scheduled-Parquet export is a newer release. Meanwhile **ClickHouse writes true Parquet regardless** (Part B). Lesson for self-hosters: pin versions and validate API surface against the *running* image, not the docs.

5. **ClickHouse ≥ 25.11 matters for Parquet exports.** On older ClickHouse, Langfuse's Parquet blob-storage export can "succeed" (manifest written) while producing an invalid/incomplete file. Our host runs **25.11.2.24**, which surfaces such failures reliably. Below that, prefer CSV/JSON/JSONL.

6. **Overlays are independent; expect orphan warnings.** Each feature (masking, governance) is a separate compose overlay. Bringing one up recreates `web`/`worker` with *that* overlay's env only — so running lab 10 dropped lab 08's masking wiring and printed an orphan-container warning. Combine overlays (`-f … -f …`) to run several features at once.

7. **Portability fix applied during the run.** The lab-08 driver hard-coded `python`, which doesn't exist on macOS (only `python3`). It now auto-detects the interpreter, preferring `.venv/bin/python`, so it runs without manual venv activation.

## Reproduce it

```bash
cd usecase/langfuse-ee
cp .env.example .env                 # set LANGFUSE_EE_LICENSE_KEY + ADMIN_API_KEY for 05–11
python3 -m venv .venv && ./.venv/bin/pip install "langfuse>=3"

./01-up.sh                           # OSS stack
./.venv/bin/python 02-generate-traces.py
docker compose exec -T clickhouse clickhouse-client -u clickhouse --password clickhouse --multiquery < 03-clickhouse-explore.sql
docker compose exec -T clickhouse clickhouse-client -u clickhouse --password clickhouse --multiquery < 04-clickhouse-analytics.sql

./05-ee-activate.sh                  # → EE
./06-ee-rbac-scim.sh
./07-ee-audit-retention.sh
./08-ee-data-masking.sh              # ⭐ masking proof in ClickHouse
./09-ee-protected-prompts.sh
./10-ee-instance-governance.sh
./11-ee-parquet-export.sh            # Parquet ↔ ClickHouse round-trip

./99-cleanup.sh --purge              # tear down + wipe volumes
```

---

## 한국어 블로그 아웃라인 (Korean blog outline)

바로 글로 옮길 수 있도록 정리한 서술 구조입니다.

**제목(안):** "Langfuse를 ClickHouse 위에서 셀프호스팅하기 — 엔터프라이즈 기능까지 직접 돌려본 기록"

1. **왜 이 글인가** — 대부분의 Langfuse 튜토리얼은 "Cloud에 trace 보내기"에서 끝난다. 이 글은 셀프호스팅 + 그 밑을 떠받치는 **ClickHouse 백엔드**를 SA 관점에서 직접 열어본다. (환경표: Langfuse v3.197.1 / ClickHouse 25.11.2.24)
2. **아키텍처 한 장** — web·worker + Postgres(OLTP: 사용자·조직·프롬프트·감사로그) + **ClickHouse(OLAP: trace·observation·score)** + Redis + MinIO. "trace는 Postgres에 없다, ClickHouse에 있다."
3. **OSS 트랙 (01–04)** — headless init로 클릭 없이 부팅 → SDK로 40 trace → **ClickHouse SQL로 비용/지연 p95/품질 분석**. 여기서 **ReplacingMergeTree 함정**(raw 41 → FINAL 40) 설명. (발견 #2)
4. **Enterprise 트랙 (05–11)** — 라이선스 활성화 → Instance Management API 200. RBAC/SCIM로 **조직 전체 VIEWER지만 특정 프로젝트만 ADMIN**인 Bob(발견: 프로젝트 단위 RBAC). 데이터 보존 + 감사 로그.
5. **하이라이트: 서버측 데이터 마스킹을 ClickHouse로 *증명*** — PII/시크릿을 심은 trace 전송 → `position()`으로 원문 부재(=0) + `[REDACTED_*]` 존재(24행) 확인. "마스킹한다"를 **검증 가능한 명제**로 바꾸는 게 핵심. (발견 #1)
6. **프롬프트 거버넌스** — `production` 라벨이 v1→v2로 **이동**(v1 labels=`{}`)하는 것을 보고 왜 protected label이 필요한지 연결. (발견 #3)
7. **데이터 반출: Parquet ↔ ClickHouse 라운드트립** — `INSERT INTO FUNCTION s3(...)` → 되읽기 **93==93**. archive-then-delete. 그리고 **버전 드리프트 함정**: 통합 API가 v3.197.1에서 `PARQUET` 거부(400) — 공개 OpenAPI 스펙이 실행 이미지보다 앞섬. + **CH ≥ 25.11** 권장 이유. (발견 #4, #5)
8. **운영 메모** — 오버레이 독립성/orphan 경고(발견 #6), macOS `python` 이식성(발견 #7).
9. **마무리** — 셀프호스팅 Langfuse는 사실상 실전 ClickHouse 애플리케이션이며, ClickHouse가 있으면 관측성·컴플라이언스(마스킹·보존·반출)를 *데이터로* 증명할 수 있다.

**추천 코드/캡처:** 마스킹 leak=0 SQL, RMT raw vs FINAL, 프롬프트 라벨 이동 테이블, blob-storage 400 응답, `s3()` 93==93. (모두 위 로그에서 그대로 인용 가능)

---

*Full per-lab console logs from this run are archived under `/tmp/lab-logs/` on the run host. Generated 2026-07-26 by running every script in this directory end-to-end.*
