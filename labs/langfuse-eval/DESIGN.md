# Design — `usecase/langfuse-eval/` : The Langfuse Quality Loop

> 상태: **구현 완료 · 2026-07-26 end-to-end 검증** — 최신/권위 있는 검증 결과는 [README.md](README.md) 참조. (이 문서는 설계 근거 기록용으로 유지)
> 작성일: 2026-07-25 · 작성자: Ken Lee (ClickHouse SA)
> 자매 랩: [`usecase/langfuse-ee/`](../langfuse-ee/README.md) (self-host + ClickHouse 백엔드 + EE governance)

---

## 1. 목적 & 포지셔닝

기존 `usecase/langfuse-ee/` 랩은 **"self-host 배포 → 관측(observability) → ClickHouse 백엔드 → EE governance(RBAC/SCIM/Audit/Retention)"** 를 다룬다.
빠진 축은 **Langfuse가 관측 플랫폼을 넘어 제공하는 "LLM 품질 관리 제품 기능"** 이다.

이 랩은 그 빈틈을 채운다. 하나의 서사로 Langfuse **제품 기능**을 꿴다:

> **프롬프트를 버전 관리하고 → 골든 데이터셋을 만들고 → 실험으로 버전/모델을 비교하고 → 자동·휴먼 평가로 점수를 매기고 → 그 점수가 ClickHouse에 어떻게 쌓여 분석되는지 본다.**

### 기존 랩과의 관계
- **스택 재사용**: 새 컨테이너를 띄우지 않는다. `usecase/langfuse-ee/`의 실행 중인 스택(같은 `.env`, 같은 포트 3000)을 그대로 쓴다. README 상단에 "먼저 자매 랩의 `01-up.sh`로 스택을 올려라"를 명시.
- **관측 vs 품질**: 관측(trace가 어떻게 흐르나)은 기존 랩, 품질(그 trace를 어떻게 평가/개선하나)은 이 랩. 디렉터리를 분리해 서사가 섞이지 않게 한다.

### 라이선스 (검증 완료)
Langfuse 라이선스 페이지 기준, 이 랩이 다루는 기능은 **전부 OSS(MIT)** 다. EE 전용은 governance 계열(RBAC/SCIM/Audit/Retention/Protected labels/Data masking)뿐이고 이는 기존 랩이 이미 커버.
→ **이 랩은 라이선스 키가 필요 없다.** 유일한 외부 의존성은 managed LLM-as-a-judge용 실 LLM API 키인데, 이는 **선택**이며 code evaluator로 오프라인 대체된다(§5 하이브리드).

---

## 2. 서사 (The Quality Loop)

```
        ┌──────────────────────────────────────────────────────────┐
        │                    THE QUALITY LOOP                        │
        │                                                            │
   (02) Prompt Mgmt ──► (03) Dataset ──► (04) Experiment            │
   버전·라벨·compile     골든 테스트셋      prompt v1 vs v2 / model A·B │
        ▲                                      │                     │
        │                                      ▼                     │
   (06) Annotation ◄──── (05) Evaluators ◄─────┘                     │
   휴먼 검수 루프          code(오프라인) + LLM-judge(선택)            │
        │                                      │                     │
        └──────────────┬───────────────────────┘                    │
                       ▼                                             │
              (07) scores in ClickHouse                              │
              API/EVAL/ANNOTATION 통합 점수 모델 분석  ◄── SA 앵글    │
        └──────────────────────────────────────────────────────────┘
```

핵심 메시지: **user-feedback·code eval·LLM judge·human annotation — 출처가 다른 모든 품질 신호가 결국 ClickHouse `scores` 한 테이블로 수렴**하고, 그래서 UI가 안 보여주는 교차 분석(예: 휴먼 vs LLM judge 일치도)을 SQL로 할 수 있다.

---

## 3. 파일 구조 (제안)

```
usecase/langfuse-eval/
├── README.md                    # 한/영 bilingual (기존 랩 골격 재사용)
├── DESIGN.md                    # 이 문서 (검토 후 삭제 or docs/로 이동)
├── .env.example                 # 자매 랩 .env 재사용 + 평가용 키 추가 (§8)
├── _env.sh                      # 자매 랩에서 복사 (자격증명 로딩 헬퍼)
├── 01-seed-traces.py            # 기존 02-generate-traces.py 재사용 래퍼 — 평가 대상 trace 확보
├── 02-prompt-management.py      # 프롬프트 생성·버전·라벨·compile·generation 링크
├── 03-datasets.py               # 골든 테스트셋 구축 (input + expected_output)
├── 04-experiments.py            # run_experiment: prompt/model 비교 + code evaluator, run 비교 출력
├── 05-llm-as-a-judge.sh + .md   # managed evaluator 설정 가이드 + (키 있으면) API 설정 실행
├── 06-annotation-queue.py       # score config + 큐 생성 + 아이템 추가 (휴먼 검수 루프)
├── 07-scores-in-clickhouse.sql  # 통합 점수 모델 분석 (SA 앵글)
└── 99-cleanup.py                # 이 랩이 만든 프롬프트/데이터셋/큐만 정리 (스택은 안 내림)
```

> 번호 규칙은 기존 랩과 동일(2자리, 실행 순서). `01`은 seed라 자매 랩의 `02`와 역할이 겹치지만, 이 랩만 독립 실행 가능하도록 얇은 래퍼로 둔다.

---

## 4. 파일별 상세 스펙

각 스크립트는 **(a) 무엇을 하는가 · (b) 핵심 SDK/API · (c) 무엇이 생기나 · (d) 관찰 포인트(UI + ClickHouse) · (e) 검증 기준** 을 따른다.

### 01 — Seed traces (`01-seed-traces.py`)
- **(a)** 평가 대상이 될 trace를 확보. 기존 [`../langfuse-ee/02-generate-traces.py`](../langfuse-ee/02-generate-traces.py)를 import/재사용하는 얇은 래퍼. 기본 40건.
- **(b)** 기존 로직 그대로 (`start_as_current_observation`, `create_score`, `flush`).
- **(c)** `traces`/`observations`/`scores`(source=API) 행.
- **(d)** UI → Tracing. 이후 06 annotation, 05 production-trace 평가의 입력.
- **(e)** `auth_check()` 통과 + N건 적재 확인.
- **재사용 판단**: 코드 복제 대신 `sys.path`로 자매 랩 모듈 import. ⚠️ 구현 시: 상대 import 경로 안정성 확인, 안 되면 최소 복제.

### 02 — Prompt Management (`02-prompt-management.py`)
- **(a)** 프롬프트를 코드에서 분리해 Langfuse에 저장·버전·배포. support-assistant 시스템 프롬프트를 **v1(간결) → v2(가드레일 강화)** 로 진화시키고 라벨로 배포 제어.
- **(b)** (확인 완료)
  ```python
  langfuse.create_prompt(name="support-system", type="text",
      prompt="You are a helpful support assistant. Answer in one sentence.",
      labels=["production"], config={"model":"gpt-4o-mini","temperature":0.2})
  # v2 — 라벨을 옮겨 배포 전환
  langfuse.create_prompt(name="support-system", type="text",
      prompt="You are a support assistant. Answer in one sentence. "
             "If unsure, say you will escalate. Never invent policy.",
      labels=["production","latest"])
  prompt = langfuse.get_prompt("support-system", label="production")
  text = prompt.compile()                       # 변수 있으면 compile(**vars)
  ```
  - chat 프롬프트도 1개 만들어 text vs chat 대비.
  - **generation 링크**: generation 생성 시 프롬프트 객체를 연결 → UI에서 "이 프롬프트 버전이 낸 성능" 분석 가능. ⚠️ 구현 시: v3 OTEL SDK의 정확한 링크 파라미터명 확인(`prompt=` vs `langfuse_prompt=`). 문서 재확인 필요.
- **(c)** Postgres에 프롬프트 2개(각 다중 버전) + 라벨.
- **(d)** UI → Prompts (버전 히스토리, 라벨, diff). CH에는 프롬프트 자체가 없음(OLTP) — 대신 링크된 generation의 성능이 trace로.
- **(e)** `get_prompt(label="production")`가 v2를 반환, `latest`도 v2. compile 결과 문자열 정확.
- **강조 포인트**: 라벨 이동 = 무배포 롤백/승격. "PM이 UI에서 프롬프트 고치면 코드 배포 없이 반영" 서사.

### 03 — Datasets (`03-datasets.py`)
- **(a)** 재사용 가능한 골든 테스트셋 구축. 기존 trace generator의 `QUESTIONS`/`ANSWERS`(10쌍)를 dataset item으로 승격 → `input`=질문, `expected_output`=정답.
- **(b)** (확인 완료)
  ```python
  langfuse.create_dataset(name="support-golden-qa",
      description="10 canonical support Q&A pairs", metadata={"domain":"support"})
  langfuse.create_dataset_item(dataset_name="support-golden-qa",
      input={"question": q}, expected_output=a, metadata={"topic": ...})
  ```
- **(c)** Postgres: dataset + N개 dataset_item.
- **(d)** UI → Datasets. 04 실험의 입력.
- **(e)** 아이템 수 == len(QUESTIONS), 재실행 idempotent(중복 생성 방지 — 이름 기준 upsert or 존재 체크). ⚠️ 구현 시: item 중복 방지 전략 확정.

### 04 — Experiments (`04-experiments.py`) ★ 랩의 심장
- **(a)** 데이터셋 위에서 **프롬프트 v1 vs v2**(그리고 여력되면 **모델 A vs B**)를 실험으로 비교. 각 run이 자동으로 trace를 만들고 dataset item에 연결.
- **(b)** (확인 완료 — 현행 고수준 API)
  ```python
  from langfuse import Evaluation, get_client
  dataset = get_client().get_dataset("support-golden-qa")

  def make_task(prompt_label):
      def task(*, item, **kwargs):
          sys_prompt = get_client().get_prompt("support-system", label=prompt_label).compile()
          # 오프라인: 시뮬레이션 답변 / 키 있으면 실제 LLM 호출
          return generate_answer(sys_prompt, item.input["question"])
      return task

  # 코드(오프라인) evaluator — 키 불필요, 결정적
  def keyword_match(*, input, output, expected_output, **kwargs):
      hit = any(w in output.lower() for w in expected_output.lower().split()[:3])
      return Evaluation(name="keyword-match", value=1.0 if hit else 0.0)

  def length_ok(*, output, **kwargs):
      return Evaluation(name="length-ok", value=1.0 if len(output) < 300 else 0.0)

  result_v1 = dataset.run_experiment(name="prompt-v1", task=make_task("production"),
                                     evaluators=[keyword_match, length_ok])
  result_v2 = dataset.run_experiment(name="prompt-v2", task=make_task("latest"),
                                     evaluators=[keyword_match, length_ok])
  print(result_v1.format()); print(result_v2.format())
  ```
  - `Evaluation(name, value, comment?)` 반환. evaluator 시그니처는 keyword-only(`*`, `input/output/expected_output/metadata`).
  - ⚠️ 구현 시: `run_experiment`/`Evaluation`/`item` 속성명(`item.input`, `item.expected_output`) 정확한 최신 시그니처를 문서로 재확인(SDK 버전에 민감).
- **(c)** Postgres: dataset_run 2개 + dataset_run_items. ClickHouse: run당 trace/observation + code eval **scores(source=EVAL 또는 API)**. ⚠️ 구현 시: run_experiment가 만든 score의 `source` 값 실측(EVAL/API 여부).
- **(d)** UI → Datasets → Runs 나란히 비교(run별 평균 스코어). CH에서 run 간 스코어 delta.
- **(e)** 두 run 모두 완료, `result.format()`에 aggregate 스코어 출력, UI에서 v2 ≥ v1 경향(프롬프트가 개선이라면).

### 05 — LLM-as-a-Judge (하이브리드) (`05-llm-as-a-judge.sh` + `.md`)
- **결정**: **하이브리드** — 오프라인 code judge를 기본, 실 키 있으면 managed LLM-as-a-judge까지.
- **(a) 두 경로**:
  1. **오프라인 (기본, 키 불필요)** — 04의 evaluator 목록에 **in-code LLM-judge 흉내** evaluator 추가(결정적 rubric 기반 점수). 항상 실행/검증됨.
  2. **Managed (실 LLM 키 있을 때)** — Langfuse UI/API로 managed evaluator를 등록해 dataset run 또는 production trace를 자동 채점.
- **(b)** managed 경로:
  - 전제: Langfuse **LLM Connections**에 API 키 등록(OpenAI/Anthropic, structured-output 지원 모델 필수).
  - 사전 제작 evaluator 라이브러리: **Hallucination · Context-Relevance · Toxicity · Helpfulness** (+ Ragas).
  - 타깃: (i) production traces(샘플링 %) 또는 (ii) offline dataset runs.
  - 변수 매핑: `{{input}}`/`{{output}}`/`{{ground_truth}}` → trace 필드.
  - ⚠️ Evaluator/Eval-rule API는 **unstable**(문서 명시). `.sh`는 `npx langfuse-cli api __schema`로 현재 엔드포인트를 먼저 탐색한 뒤 호출하도록 작성. UI 스크린샷/수동 단계 fallback을 `.md`에 문서화.
- **(c)** ClickHouse `scores` (source=**EVAL**), 채점된 trace/observation에 부착.
- **(d)** UI → Evaluators / trace 상세의 자동 스코어. CH에서 human vs EVAL 스코어 비교(07로 연결).
- **(e)** 오프라인 judge는 무조건 통과. managed는 키 있을 때만 — `.sh`가 키 부재 시 우아하게 skip하고 문서 경로 안내.
- **왜 `.sh`+`.md` 조합**: 실행 가능 부분(키 있으면)과 UI 클릭/개념 설명(불안정 API 회피)을 분리.

### 06 — Annotation Queue (`06-annotation-queue.py`)
- **(a)** 휴먼 검수 루프. score config(채점 차원)를 정의하고 큐를 만들어 01/04가 만든 trace를 담는다. "도메인 전문가가 UI에서 채점" 시나리오.
- **(b)** score config + annotation queue + queue items — 전부 Public API.
  - score config 예: `answer-quality`(CATEGORICAL: good/ok/bad), `factually-correct`(BOOLEAN).
  - ⚠️ 구현 시: 정확한 엔드포인트를 `npx langfuse-cli api __schema`로 확인. 후보: `POST /api/public/score-configs`, `POST /api/public/annotation-queues`, `POST /api/public/annotation-queues/{id}/items`. SDK 헬퍼 유무도 확인(없으면 REST 직접).
- **(c)** Postgres: queue + config. 사람이 채점하면 ClickHouse `scores` (source=**ANNOTATION**).
- **(d)** UI → Annotations(키보드 단축키 워크플로 안내). CH에서 ANNOTATION 소스 스코어.
- **(e)** 큐 생성 + N개 아이템 추가 확인. (실제 사람 채점은 수동 — README에 UI 단계 안내, 데모용으로 API로 스코어 몇 개 주입해 07 분석이 비지 않게.)

### 07 — Scores in ClickHouse (`07-scores-in-clickhouse.sql`) ★ SA 앵글
- **(a)** 모든 품질 신호가 `scores` 한 테이블로 수렴함을 보이고, UI가 못 하는 교차 분석을 SQL로.
- **(b)** 핵심 쿼리(전부 `FINAL` + `is_deleted=0`, 기존 랩 규칙 계승):
  | 쿼리 | ClickHouse 기능 | 메시지 |
  |---|---|---|
  | `source`별 스코어 분포 (API/EVAL/ANNOTATION) | `count() GROUP BY source, name` | 통합 점수 모델 |
  | 스코어 이름별 평균/분포 | `avg()`, `quantile()`, `countIf` by `data_type` | 수치/불리언/범주 혼재 처리 |
  | 휴먼(ANNOTATION) vs LLM judge(EVAL) 일치도 | 같은 trace_id JOIN, 값 비교 | judge 신뢰도 검증 |
  | dataset run 간 스코어 비교 | run 식별자로 필터/그룹 | 실험 A/B (04 재현) |
  | 시간대별 품질 추이 | `toStartOfDay(timestamp)` 버킷 | score-analytics를 SQL로 |
  - ⚠️ 구현 시: `DESCRIBE scores`로 컬럼 실측(`source`, `data_type`, `string_value`, `value`, `comment`, `trace_id`, `observation_id` 등). dataset run 연결이 CH만으로 되는지, PG JOIN 필요한지 확인(dataset 메타는 PG). 안 되면 trace `metadata`에 run 이름을 심어 CH만으로 그룹.
- **(c)/(d)/(e)** 기존 랩 04 스타일: 모든 쿼리가 실행되고 수치가 타당.

### 99 — Cleanup (`99-cleanup.py`)
- 이 랩이 만든 것만 삭제(프롬프트·데이터셋·큐·score config). **스택은 안 내린다**(자매 랩 소관). ⚠️ 삭제 API 지원 범위 확인 — 미지원이면 "UI에서 삭제" 안내.

---

## 5. 하이브리드 평가 전략 (요약)

| 경로 | 키 필요? | 어디서 | scores.source | 검증 |
|---|---|---|---|---|
| user-feedback (기존 seed) | ✗ | 01 SDK | API | 항상 |
| code evaluator (keyword/length/…) | ✗ | 04 `run_experiment` | EVAL/API* | 항상 |
| in-code LLM-judge (rubric 흉내) | ✗ | 04/05 | EVAL/API* | 항상 |
| **managed LLM-as-a-judge** | ✓ (LLM Connections) | 05 UI/API | EVAL | 키 있을 때만 |
| human annotation | ✗ | 06 큐 | ANNOTATION | 큐 생성 항상 / 채점 수동 |

\* `run_experiment` evaluator 결과의 정확한 `source` 값은 구현 시 실측.

→ **키 없이도 랩 전체가 실행·검증**되고(오프라인 경로), 키가 있으면 managed judge까지 end-to-end. 자매 랩의 "offline by default, real key optional" 철학과 일치.

---

## 6. `.env` 추가 항목 (§8)

자매 랩 `.env`를 그대로 상속(같은 `LANGFUSE_HOST`/`PUBLIC_KEY`/`SECRET_KEY`). 추가:

```bash
# ── 이 랩 전용 (전부 선택) ──────────────────────────────────
# managed LLM-as-a-judge & 실제 답변 생성용. 없으면 오프라인 경로로 자동 폴백.
OPENAI_API_KEY=            # 선택 — 있으면 04 실제 생성 + 05 managed judge
# ANTHROPIC_API_KEY=       # 선택 — 대안 judge 모델
EVAL_JUDGE_MODEL=gpt-4o-mini   # structured-output 지원 모델
DATASET_NAME=support-golden-qa
PROMPT_NAME=support-system
```

---

## 7. README 구조 (bilingual, 기존 랩 골격 재사용)

`[English](#english) | [한국어](#한국어)` 이중 구성. 섹션: 목적 → 서사(Quality Loop 다이어그램) → 파일 구조 → 사전 준비(자매 랩 스택 먼저) → Quick Start → 랩 워크스루(02~07) → 하이브리드 평가 설명 → Gotchas → 검증 상태 표 → 추가 자료 → MIT/Author.

Gotchas 후보:
- datasets/프롬프트는 **Postgres**, scores/traces는 **ClickHouse** (기존 랩 "두 DB" 규칙의 확장).
- managed evaluator는 **LLM Connections에 키 등록 필수** + structured-output 모델.
- Evaluator API는 **unstable** — UI 또는 `__schema`로 현재 계약 확인.
- `run_experiment` SDK 시그니처는 버전 민감 — 설치 버전 문서가 정답.
- 모든 품질 신호는 `scores`의 `source`(API/EVAL/ANNOTATION)로 구분된다.

---

## 8. 검증 계획 (빌드 후 채울 표)

| 단계 | 검증 기준 | 상태 |
|---|---|---|
| 01 seed | N traces 적재 | ⬜ |
| 02 prompt | v1→v2 라벨 이동, get/compile 정확 | ⬜ |
| 03 dataset | item 수 정확, idempotent | ⬜ |
| 04 experiment | 2 run 완료, aggregate 스코어, UI 비교 | ⬜ |
| 05 judge (offline) | code/in-code judge 스코어 부착 | ⬜ |
| 05 judge (managed) | 키 있을 때 EVAL 스코어 생성 | ⬜ (키 의존) |
| 06 annotation | 큐+config 생성, item 추가 | ⬜ |
| 07 CH scores | 전 쿼리 실행, source 3종 확인 | ⬜ |

목표 검증 환경: 자매 랩과 동일(Langfuse v3.19x, Docker Compose). 빌드 시 실제 버전 기록.

---

## 9. 구현 전 확인(⚠️) 목록 — 빌드 첫 단계에서 문서/`__schema`로 해소

1. v3 OTEL SDK의 프롬프트→generation **링크 파라미터명**.
2. `dataset.run_experiment` / `Evaluation` / `item.*` **최신 시그니처**.
3. `run_experiment` evaluator 스코어의 **`source` 실측값**.
4. **annotation queue / score-config** 정확한 REST 엔드포인트 & SDK 헬퍼 유무.
5. **dataset run ↔ ClickHouse** 연결 방식(CH 단독 vs PG JOIN vs trace metadata).
6. `DESCRIBE scores` 실제 컬럼(설치 버전 기준).
7. 삭제 API 지원 범위(99 cleanup).
8. 01 seed의 자매 랩 모듈 **import 경로** 안정성.

---

## 10. 미결 결정 (Ken 확인 요청)

- **A.** 04 실험의 두 번째 축으로 **모델 비교(gpt-4o-mini vs gpt-4o 등)** 까지 넣을까, 프롬프트 v1/v2 비교만으로 충분한가? (모델 비교는 실 키 없으면 시뮬레이션이라 설득력 약함)
- **B.** 06 annotation은 사람이 UI에서 채점해야 07 분석이 풍부해짐 → **데모용으로 API로 스코어 몇 개 주입**해 07이 비지 않게 할까(권장), 아니면 순수 "UI에서 직접 해보라"로 둘까?
- **C.** `DESIGN.md`는 검토 후 **삭제** vs `docs/`로 이동 vs README에 흡수?
```

