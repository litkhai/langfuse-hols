# The Langfuse Quality Loop — Prompts, Datasets, Experiments & Evals (on ClickHouse)

[English](#english) | [한국어](#한국어)

---

## English

A hands-on tour of Langfuse's **product features for LLM quality** — prompt
management, datasets, experiments, LLM-as-a-judge, and human annotation — then a
look at how every quality signal lands in the **ClickHouse** backend.

This is the sibling of [`labs/langfuse-ee/`](../langfuse-ee/README.md). Where that
lab covers *self-hosting + the ClickHouse backend + Enterprise governance*, this one
answers a different question: **once Langfuse is running, how do you actually use it
to measure and improve LLM quality?**

> **Everything here is OSS (MIT) — no license key required.** The only optional
> extra is an Anthropic API key, used for real answer generation (`claude-haiku-4-5`),
> the LLM judge and Langfuse's *managed* LLM-as-a-judge; without it the lab runs fully
> offline with code evaluators. It runs on the **Langfuse v4** stack pinned in `_base/`,
> where observations (not traces) are the unit stored in ClickHouse.

### 🔁 The quality loop

```
   (02) Prompt Mgmt ──► (03) Dataset ──► (04) Experiment ──► (05) LLM-judge
   version · label       golden Q&A       prompt v1 vs v2      grade correctness
        ▲                                       │                    │
        │                                       ▼                    ▼
        └────────────── (06) Annotation ◄── human review ──► (07) scores in ClickHouse
                         score configs + queue                 API · EVAL · ANNOTATION
```

Every signal — user feedback, code evaluators, the LLM judge, human annotations —
converges into one ClickHouse table (`scores`), distinguished by `source`. That
lets you run cross-cutting quality analytics the UI doesn't offer.

### 📁 File structure

```
langfuse-eval/
├── README.md                   # this file
├── _common.py                  # shared: _base/.env loader, client, REST helper, the Q&A KB
├── 01-seed-traces.py           # seed traces to evaluate with the shared generator (_base/bin/seed_traces.py)
├── 02-prompt-management.py     # versions, labels (production/latest), compile, prompt→trace link
├── 03-datasets.py              # a golden test set (input + expected_output), idempotent
├── 04-experiments.py           # run_experiment: prompt v1 vs v2 + code evaluators
├── 05-llm-as-a-judge.py        # hybrid judge (offline rubric / real LLM) as an evaluator
├── 05-llm-as-a-judge.md        # guide: Langfuse's MANAGED, observation-level evaluators (+ the API calls)
├── 06-annotation-queue.py      # score configs + queue + enqueue traces (human-in-the-loop)
├── 07-scores-in-clickhouse.sql # the payoff: every signal, unified, in ClickHouse
└── 99-cleanup.py               # remove this lab's artifacts (best-effort; stack untouched)
```

### ✅ Prerequisites

- **The shared stack in [`_base/`](../../_base/README.md) must be running.** From the repository root:
  ```bash
  _base/bin/up.sh      # brings up web/worker/postgres/clickhouse/redis/minio (creates _base/.env from the template on first run)
  _base/bin/check.sh   # optional: containers healthy, migrations finished, SDK keys valid
  ```
  This lab uses that stack and its `_base/.env` credentials — the same ones the `langfuse-ee` lab uses (its `01-up.sh` runs the same script).
- **Python 3.10+** (Langfuse Python SDK v4 requires it) and `pip install -r _base/requirements.txt` — the packages are pinned there.
- *(optional)* `ANTHROPIC_API_KEY` in `_base/.env` for real generation (`claude-haiku-4-5`) + the LLM judge. The real calls use the official `anthropic` SDK, traced by `opentelemetry-instrumentation-anthropic`.

### 🚀 Quick start (offline — no LLM key needed)

```bash
cd labs/langfuse-eval
python3.12 -m venv ../../.venv && source ../../.venv/bin/activate   # Python 3.10+; one venv for both labs
pip install -r ../../_base/requirements.txt

python 01-seed-traces.py 20        # seed traces to evaluate
python 02-prompt-management.py     # version + label + compile + link a prompt
python 03-datasets.py              # build the golden Q&A dataset
python 04-experiments.py           # compare prompt v1 vs v2 with code evaluators
python 05-llm-as-a-judge.py        # add an LLM-judge score (offline rubric by default)
python 06-annotation-queue.py      # create the human-review queue + demo scores

# Explore how every score lands in ClickHouse (scores ingest asynchronously — give 06 ~10 s):
docker exec -i langfuse-hols-clickhouse-1 clickhouse-client \
  -u clickhouse --password clickhouse --multiquery < 07-scores-in-clickhouse.sql
```

### 📖 Lab walkthrough

#### 02 — Prompt management
Store the support system-prompt in Langfuse, not in code. Create **v1** (terse) and
**v2** (guard-railed); creating v2 with the `production` label instantly **deploys**
it (label moves to v2) while v1 stays reachable by version number. Fetch with
`get_prompt(label="production")`, fill variables with `.compile(tone="friendly")`,
and **link** a prompt to a generation with the `prompt=` parameter so the UI can
attribute performance to that version. Prompts live in Postgres.

#### 03 — Datasets
A dataset is a reusable set of test cases (`input` + `expected_output`). We promote
10 canonical support Q&A pairs into items. Passing a stable `id=` makes re-runs
**idempotent** (upsert, not duplicate).

#### 04 — Experiments *(the heart)*
`dataset.run_experiment(name, task, evaluators=[…])` runs a task over every item,
auto-traces each run, and scores it. We run it twice — **prompt-v1 vs prompt-v2** —
with three **code evaluators** (no LLM key): `keyword-recall`, `length-ok`,
`answered`. Each experiment trace is tagged with its variant so ClickHouse can
reconstruct the A/B (lab 07): SDK v4's `propagate_attributes()` wraps the
`run_experiment()` call, which puts the tag on every observation of the trace,
including the root one. Compare the two runs side by side in the UI.

#### 05 — LLM-as-a-judge *(hybrid)*
Use a model to grade the output. Runs an experiment whose evaluator is a judge:
offline it uses a deterministic rubric; with `ANTHROPIC_API_KEY` it makes a real
grading call to Claude. For Langfuse's fully **managed** evaluators — **observation-level**
evaluators plus a rule that run continuously on live observations (trace-level ones are
*Legacy* and stop running in v4's `events_only` mode) — see
[05-llm-as-a-judge.md](05-llm-as-a-judge.md): they need an Anthropic connection under
*LLM Connections* (UI or API) and write `source = 'EVAL'`.

#### 06 — Annotation queues
Human-in-the-loop scoring. Create **score configs** (`answer-quality` categorical,
`factually-correct` boolean), a **queue** bound to them, and enqueue seed traces for
review. All via the Public REST API (Basic auth). On v4 the trace linkage comes from
`GET /api/public/v3/scores?fields=subject` (the older score endpoints answer 404), and a trace
is enqueued as an `OBSERVATION` item holding its root observation's id. A few demo review
scores are written so lab 07 has data; **real** UI annotations arrive with `source = 'ANNOTATION'`.

#### 07 — Scores in ClickHouse *(the SA payoff)*
Pure SQL on the `scores` table (read with `FINAL` + `is_deleted = 0`):
| Query | What it shows |
|---|---|
| Unified model by `source`/`name` | every signal in one table (API / EVAL / ANNOTATION) |
| Volume by `data_type` | numeric vs boolean vs categorical |
| Numeric distribution (p50/p90) | per-metric spread |
| **Experiment A/B by variant** | `scores → events_core` root-row join reconstructs v1 vs v2 |
| Per-trace agreement | user-thumbs vs hallucination-check vs human review, same trace |
| Daily trend | judged correctness over time |

### 🔑 Gotchas worth remembering

| | Note |
|---|---|
| **Two databases** | Prompts + datasets + queues live in **Postgres**; traces + **scores** live in **ClickHouse**. |
| **SDK scores are `source=API`** | Code/LLM-judge scores written via the SDK are `source=API`. Only Langfuse's **managed** evaluators write `EVAL`; UI annotations write `ANNOTATION`. |
| **`config_id` is strict** | A score bound to a score config must match that config's exact `data_type`, or ingestion drops it. Demo scores here are unbound. |
| **Run id not in `scores`** | Evaluator scores don't carry `dataset_run_id` in CH — tag experiment traces (lab 04 does) and join `scores → events_core` root rows to reconstruct an A/B. (v4 also stamps `experiment_name` on every event row.) |
| **Tags must reach the root row** | Attributes set *inside* the `run_experiment` task start one level below the root `experiment-item-run` row. Wrap the `run_experiment()` call in `propagate_attributes()` so the root carries them too. |
| **Async ingestion** | Scores flow SDK → worker → ClickHouse asynchronously; allow a few seconds before querying `scores`. |
| **`flush()` in scripts** | Short scripts must `flush()` before exit or lose buffered data. |
| **Managed judge needs a key** | Managed LLM-as-a-judge requires a structured-output model configured in *LLM Connections* (here the Anthropic adapter), and an **observation-level** evaluator: trace-level evaluators stop running in `events_only` mode. |

### 📝 Verification status

Verified **end-to-end on 2026-10-02** against **Langfuse v4.48.0 / SDK 4.16.0 / ClickHouse 26.8.15.10**.

- **Stack:** the pinned shared stack in [`_base/`](../../_base/README.md), Python 3.12.14.
- **Offline:** every step ran offline.
- **Real model calls:** steps 04 and 05 also ran with real calls to Anthropic `claude-haiku-4-5`. Step 05's managed evaluator ran through an Anthropic LLM connection.

The full log is in [lab-output.md](lab-output.md).

| Step | Result |
|---|---|
| `01` seed | 20 traces ingested through the shared generator (`_base/bin/seed_traces.py`) |
| `02` prompts | v1 + v2 + chat created; `production` label moved to v2; compile + `prompt=` link OK |
| `03` dataset | 10 items upserted (`golden-00…09`), idempotent |
| `04` experiments | offline: prompt-v1 `answered 0 / keyword-recall 0` → prompt-v2 `1 / 1`; real `claude-haiku-4-5`: keyword-recall v1 **0.326** → v2 **0.169** |
| `05` LLM-judge | offline rubric `0 → 1`; real judge v1 **0.415** → v2 **0.215**; managed observation-level evaluator wrote **5 `EVAL` scores** (avg 0.95) |
| `06` annotation | 2 score configs + `human-review` queue + 8 root observations enqueued (`objectType: OBSERVATION`) + demo scores |
| `07` ClickHouse | all sections return rows; the A/B join `scores → events_core` root rows works; per-trace agreement populated; `API` and `EVAL` sources side by side |

Runtime findings built into the labs:

1. **Sources.** `run_experiment` evaluator scores are `source=API`, and the managed evaluator writes `EVAL`.
2. **Run linkage.** Evaluator scores carry `observation_id` but not `dataset_run_id` in ClickHouse (0 of 40). So lab 04 tags the experiment root rows with the variant, and lab 07 joins `scores → events_core`.
3. **Scores API.** `/v2/scores` answers 404 on v4. `/v3/scores` needs `fields=subject` for the trace linkage.
4. **Ingestion is asynchronous.** Give step 06 about ten seconds before step 07.
5. **Simulation ≠ model.** With the real model the guard-railed v2 prompt scored *lower*.

### 🔍 Resources
- [Prompt Management](https://langfuse.com/docs/prompt-management/overview)
- [Datasets & Experiments](https://langfuse.com/docs/evaluation/experiments/experiments-via-sdk)
- [Evaluation overview](https://langfuse.com/docs/evaluation/overview) · [LLM-as-a-judge](https://langfuse.com/docs/evaluation/evaluation-methods/llm-as-a-judge) · [Annotation queues](https://langfuse.com/docs/evaluation/evaluation-methods/annotation-queues)
- [Python SDK v3 → v4](https://langfuse.com/docs/observability/sdk/upgrade-path/python-v3-to-v4) · [Anthropic integration (OpenTelemetry)](https://langfuse.com/integrations/model-providers/anthropic) · [Upgrade trace-level evaluators](https://langfuse.com/faq/all/llm-as-a-judge-migration)

### 📝 License
[MIT](../../LICENSE) — same as the rest of the repository.

### 👤 Author
Ken Lee (ClickHouse Solution Architect) — ken.lee@clickhouse.com
Created: 2026-07-26

---

**Happy Evaluating! 🎯** — for the deployment/governance side, see [`labs/langfuse-ee/`](../langfuse-ee/README.md).

---

## 한국어

Langfuse의 **LLM 품질 관리 제품 기능** — 프롬프트 관리, 데이터셋, 실험,
LLM-as-a-judge, 휴먼 어노테이션 — 을 직접 돌려보고, 그 모든 품질 신호가 **ClickHouse**
백엔드에 어떻게 쌓이는지까지 보는 실습입니다.

이 랩은 [`labs/langfuse-ee/`](../langfuse-ee/README.md)의 자매 랩입니다. 그 랩이
*self-hosting + ClickHouse 백엔드 + Enterprise governance* 를 다뤘다면, 이 랩은 다른
질문에 답합니다: **Langfuse를 띄운 뒤, 실제로 LLM 품질을 측정하고 개선하려면 어떻게
쓰는가?**

> **여기 나오는 기능은 전부 OSS(MIT) — 라이선스 키 불필요.** 유일한 선택 항목은 실제 답변
> 생성(`claude-haiku-4-5`)과 LLM 판정, Langfuse의 *managed* LLM-as-a-judge용 Anthropic API
> 키이며, 없으면 코드 평가자로 완전 오프라인 실행됩니다. `_base/`에 고정된 **Langfuse v4**
> 스택에서 실행되며, ClickHouse에 저장되는 단위는 trace가 아니라 observation입니다.

### 🔁 품질 루프

```
   (02) 프롬프트 관리 ─► (03) 데이터셋 ─► (04) 실험 ──────► (05) LLM 판정
   버전·라벨            골든 Q&A         프롬프트 v1 vs v2    정확도 채점
        ▲                                     │                  │
        │                                     ▼                  ▼
        └──────────── (06) 어노테이션 ◄── 휴먼 검수 ──► (07) ClickHouse의 scores
                       score config + 큐               API · EVAL · ANNOTATION
```

모든 신호 — 사용자 피드백·코드 평가자·LLM 판정·휴먼 어노테이션 — 가 결국 ClickHouse의 한
테이블(`scores`)로 수렴하며 `source`로 구분됩니다. 덕분에 UI가 제공하지 않는 교차 분석을
SQL로 할 수 있습니다.

### 📁 파일 구조

```
langfuse-eval/
├── README.md                   # 이 문서
├── _common.py                  # 공통: _base/.env 로더, 클라이언트, REST 헬퍼, Q&A 지식베이스
├── 01-seed-traces.py           # 공유 생성기(_base/bin/seed_traces.py)로 평가 대상 trace 확보
├── 02-prompt-management.py     # 버전·라벨(production/latest)·compile·프롬프트→trace 링크
├── 03-datasets.py              # 골든 테스트셋(input + expected_output), 멱등
├── 04-experiments.py           # run_experiment: 프롬프트 v1 vs v2 + 코드 평가자
├── 05-llm-as-a-judge.py        # 하이브리드 판정(오프라인 rubric / 실제 LLM)
├── 05-llm-as-a-judge.md        # 가이드: Langfuse MANAGED, observation 수준 평가자(+ API 호출)
├── 06-annotation-queue.py      # score config + 큐 + trace 적재(휴먼 검수)
├── 07-scores-in-clickhouse.sql # 핵심: 모든 신호를 ClickHouse에서 통합 분석
└── 99-cleanup.py               # 이 랩 산출물만 정리(best-effort; 스택은 그대로)
```

### ✅ 사전 준비물

- **[`_base/`](../../_base/README.md)의 공유 스택이 실행 중이어야 합니다.** 저장소 루트에서:
  ```bash
  _base/bin/up.sh      # web/worker/postgres/clickhouse/redis/minio 기동 (첫 실행 시 템플릿에서 _base/.env 생성)
  _base/bin/check.sh   # 선택: 컨테이너 healthy, 마이그레이션 완료, SDK 키 유효 확인
  ```
  이 랩은 그 스택과 `_base/.env` 자격증명을 사용합니다 — `langfuse-ee` 랩이 쓰는 것과 같으며, 그 랩의 `01-up.sh`도 같은 스크립트를 실행합니다.
- **Python 3.10+** (Langfuse Python SDK v4 요구사항) 와 `pip install -r _base/requirements.txt` — 패키지는 그 파일에 고정되어 있습니다.
- *(선택)* `_base/.env`의 `ANTHROPIC_API_KEY` — 실제 생성(`claude-haiku-4-5`) + LLM 판정용. 실제 호출은 공식 `anthropic` SDK를 쓰고 `opentelemetry-instrumentation-anthropic`이 추적합니다.

### 🚀 빠른 시작 (오프라인 — LLM 키 불필요)

```bash
cd labs/langfuse-eval
python3.12 -m venv ../../.venv && source ../../.venv/bin/activate   # Python 3.10+; 두 랩이 venv 하나를 공유
pip install -r ../../_base/requirements.txt

python 01-seed-traces.py 20        # 평가 대상 trace 시드
python 02-prompt-management.py     # 프롬프트 버전·라벨·compile·링크
python 03-datasets.py              # 골든 Q&A 데이터셋 구축
python 04-experiments.py           # 코드 평가자로 프롬프트 v1 vs v2 비교
python 05-llm-as-a-judge.py        # LLM 판정 스코어 추가(기본 오프라인 rubric)
python 06-annotation-queue.py      # 휴먼 검수 큐 + 데모 스코어 생성

# 모든 스코어가 ClickHouse에 어떻게 쌓이는지 탐색 (스코어는 비동기 적재 — 06 이후 ~10초 대기):
docker exec -i langfuse-hols-clickhouse-1 clickhouse-client \
  -u clickhouse --password clickhouse --multiquery < 07-scores-in-clickhouse.sql
```

### 📖 랩 워크스루

#### 02 — 프롬프트 관리
support 시스템 프롬프트를 코드가 아닌 Langfuse에 저장. **v1**(간결)과 **v2**(가드레일)를
만들고, v2를 `production` 라벨로 생성하면 라벨이 v2로 이동하며 즉시 **배포**됩니다(v1은
버전 번호로 계속 접근 가능). `get_prompt(label="production")`으로 조회,
`.compile(tone="friendly")`로 변수 치환, `prompt=` 파라미터로 generation에 **링크**하여
UI가 해당 버전의 성능을 귀속시킬 수 있게 합니다. 프롬프트는 Postgres에 저장됩니다.

#### 03 — 데이터셋
재사용 가능한 테스트 케이스 집합(`input` + `expected_output`). 10개의 표준 support Q&A를
아이템으로 승격. 고정 `id=` 를 넘기면 재실행이 **멱등**(중복 대신 upsert)입니다.

#### 04 — 실험 *(핵심)*
`dataset.run_experiment(name, task, evaluators=[…])` 는 모든 아이템에 task를 실행하고 각
run을 자동 trace + 채점합니다. **프롬프트 v1 vs v2** 로 두 번 실행하며, LLM 키 없는 세 개의
**코드 평가자**(`keyword-recall`, `length-ok`, `answered`)를 사용합니다. 각 실험 trace에
variant 태그를 달아 ClickHouse에서 A/B를 재구성할 수 있게 합니다(랩 07). SDK v4의
`propagate_attributes()`가 `run_experiment()` 호출을 감싸므로 태그가 루트를 포함한 trace의 모든
observation에 기록됩니다. UI에서 두 run을 나란히 비교하세요.

#### 05 — LLM-as-a-judge *(하이브리드)*
모델로 출력을 채점. 판정자를 평가자로 쓰는 실험을 실행합니다: 오프라인에서는 결정적
rubric, `ANTHROPIC_API_KEY` 가 있으면 Claude에 실제 채점 호출. Langfuse의 완전 **managed**
평가자 — 실시간 observation에 상시 실행되는 **observation 수준** evaluator와 rule (trace 수준은
*Legacy*이며 v4의 `events_only` 모드에서는 실행되지 않음) — 는
[05-llm-as-a-judge.md](05-llm-as-a-judge.md) 참고. *LLM Connections* 의 Anthropic connection(UI 또는 API)이
필요하며 `source = 'EVAL'` 로 기록됩니다.

#### 06 — 어노테이션 큐
휴먼 검수. **score config**(`answer-quality` 범주형, `factually-correct` 불리언), 그에 묶인
**큐** 를 만들고 시드 trace를 검수 대상으로 적재합니다. 전부 Public REST API(Basic auth).
v4에서 trace 연결 정보는 `GET /api/public/v3/scores?fields=subject`로 얻고(이전 score 엔드포인트는 404),
trace는 루트 observation의 id를 담은 `OBSERVATION` 아이템으로 적재합니다. 랩 07이 비지 않도록 데모
스코어 몇 개를 기록하며, **실제** UI 어노테이션은 `source = 'ANNOTATION'` 으로 들어옵니다.

#### 07 — ClickHouse의 scores *(SA 관점의 핵심)*
`scores` 테이블에 순수 SQL(`FINAL` + `is_deleted = 0`):
| 쿼리 | 내용 |
|---|---|
| `source`/`name`별 통합 모델 | 한 테이블 안의 모든 신호(API / EVAL / ANNOTATION) |
| `data_type`별 볼륨 | 수치 vs 불리언 vs 범주 |
| 수치 분포(p50/p90) | 지표별 분포 |
| **variant별 실험 A/B** | `scores → events_core` 루트 행 조인으로 v1 vs v2 재구성 |
| trace별 신호 일치도 | 같은 trace의 user-thumbs vs hallucination-check vs 휴먼 검수 |
| 일별 추이 | 시간에 따른 판정 정확도 |

### 🔑 기억할 함정들

| | 노트 |
|---|---|
| **두 DB** | 프롬프트·데이터셋·큐는 **Postgres**, trace·**scores**는 **ClickHouse**. |
| **SDK 스코어는 `source=API`** | SDK로 쓴 코드/LLM-judge 스코어는 `source=API`. **managed** 평가자만 `EVAL`, UI 어노테이션은 `ANNOTATION`. |
| **`config_id`는 엄격** | config에 묶인 스코어는 그 config의 `data_type`과 정확히 일치해야 함. 아니면 적재 시 드롭. 이 랩의 데모 스코어는 미연결. |
| **run id는 `scores`에 없음** | 평가자 스코어는 CH `dataset_run_id`를 채우지 않음 → 실험 trace에 태그(랩 04)하고 `scores → events_core` 루트 행 조인으로 A/B 재구성. (v4는 모든 이벤트 행에 `experiment_name`도 기록함.) |
| **태그는 루트 행까지** | `run_experiment` task *안에서* 설정한 속성은 루트 `experiment-item-run` 행보다 한 단계 아래부터 적용됨. `run_experiment()` 호출을 `propagate_attributes()`로 감싸 루트에도 기록되게 할 것. |
| **비동기 적재** | 스코어는 SDK → worker → ClickHouse 로 비동기 적재. `scores` 조회 전 몇 초 대기. |
| **스크립트의 `flush()`** | 짧은 스크립트는 종료 전 `flush()` 없으면 버퍼 데이터 유실. |
| **managed 판정은 키 필요** | managed LLM-as-a-judge는 *LLM Connections*(여기서는 Anthropic adapter)에 structured-output 모델과 **observation 수준** evaluator가 필요. trace 수준 evaluator는 `events_only` 모드에서 실행되지 않음. |

### 📝 검증 상태

**2026-10-02**에 **Langfuse v4.48.0 / SDK 4.16.0 / ClickHouse 26.8.15.10**에서 **end-to-end 검증**했습니다.

- **스택:** [`_base/`](../../_base/README.md)의 고정 공유 스택, Python 3.12.14를 썼습니다.
- **오프라인:** 모든 단계를 오프라인으로 돌렸습니다.
- **실제 모델 호출:** 04와 05는 Anthropic `claude-haiku-4-5` 실제 호출로도 돌렸고, 05의 관리형 evaluator는 Anthropic LLM connection으로 실행했습니다.

전체 로그는 [lab-output.md](lab-output.md)에 있습니다.

| 단계 | 결과 |
|---|---|
| `01` 시드 | 공유 생성기(`_base/bin/seed_traces.py`)로 trace 20건 적재 |
| `02` 프롬프트 | v1 + v2 + chat 생성; `production` 라벨 v2로 이동; compile + `prompt=` 링크 정상 |
| `03` 데이터셋 | 10개 아이템 upsert(`golden-00…09`), 멱등 |
| `04` 실험 | 오프라인: prompt-v1 `answered 0 / keyword-recall 0` → prompt-v2 `1 / 1`; 실제 `claude-haiku-4-5`: keyword-recall v1 **0.326** → v2 **0.169** |
| `05` LLM 판정 | 오프라인 rubric `0 → 1`; 실제 judge v1 **0.415** → v2 **0.215**; 관리형 observation 단위 evaluator가 **`EVAL` 스코어 5건** 기록(평균 0.95) |
| `06` 어노테이션 | score config 2개 + `human-review` 큐 + 루트 observation 8건 적재(`objectType: OBSERVATION`) + 데모 스코어 |
| `07` ClickHouse | 전 섹션 결과 반환; `scores → events_core` 루트 행 A/B 조인 동작; trace별 일치도 채워짐; `API`와 `EVAL` 출처가 함께 보임 |

랩에 반영한 런타임 발견:

1. **출처.** `run_experiment` 평가자 스코어는 `source=API`이고, 관리형 evaluator는 `EVAL`로 씁니다.
2. **실행 연결.** 평가자 스코어에는 ClickHouse에서 `observation_id`는 있지만 `dataset_run_id`는 없습니다(40건 중 0건). 그래서 랩 04가 실험 루트 행에 variant를 태그하고, 랩 07이 `scores → events_core`로 조인합니다.
3. **Scores API.** v4에서 `/v2/scores`는 404이고, `/v3/scores`는 trace 연결을 받으려면 `fields=subject`가 필요합니다.
4. **비동기 적재.** 07 전에 06 이후 10초 정도 기다리세요.
5. **시뮬레이션 ≠ 모델.** 실제 모델에서는 가드레일을 넣은 v2 프롬프트가 오히려 *낮게* 나왔습니다.

### 🔍 추가 자료
- [Prompt Management](https://langfuse.com/docs/prompt-management/overview)
- [Datasets & Experiments](https://langfuse.com/docs/evaluation/experiments/experiments-via-sdk)
- [Evaluation 개요](https://langfuse.com/docs/evaluation/overview) · [LLM-as-a-judge](https://langfuse.com/docs/evaluation/evaluation-methods/llm-as-a-judge) · [Annotation queues](https://langfuse.com/docs/evaluation/evaluation-methods/annotation-queues)
- [Python SDK v3 → v4](https://langfuse.com/docs/observability/sdk/upgrade-path/python-v3-to-v4) · [Anthropic 연동 (OpenTelemetry)](https://langfuse.com/integrations/model-providers/anthropic) · [trace 수준 evaluator 업그레이드](https://langfuse.com/faq/all/llm-as-a-judge-migration)

### 📝 라이선스
[MIT](../../LICENSE) — same as the rest of the repository.

### 👤 작성자
Ken Lee (ClickHouse Solution Architect) — ken.lee@clickhouse.com
작성일: 2026-07-26

---

**Happy Evaluating! 🎯** — 배포/거버넌스 측면은 [`labs/langfuse-ee/`](../langfuse-ee/README.md) 참고.
