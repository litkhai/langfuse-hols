# 05 — Managed LLM-as-a-Judge (companion guide)

[English](#english) · [한국어](#한국어)

`05-llm-as-a-judge.py` runs a judge **as an experiment evaluator** (works offline).
This guide covers Langfuse's **managed** LLM-as-a-judge: evaluators that Langfuse
runs *for you*, continuously, on live observations or on experiment runs.

---

## English

### What it is
An **evaluator** (the judge prompt, its `{{variables}}`, the judge model and the score
definition) plus a **rule** (which incoming observations to judge, and what share of them)
that Langfuse's *worker* executes. Each run calls the judge model through an
**LLM connection**, and writes a **score** (source `EVAL`) onto the matched observation.
This is OSS (no license key), but it needs a judge model configured.

On Langfuse v4 the target is the **observation**. A trace is its root observation, so to
judge a whole request, target the root (rule filter *Is Root Observation*) — the evaluator
sees the input and output of that one observation, not its children. The older **trace-level**
evaluators (and the legacy dataset ones) are marked *Legacy* and **stop producing results in
`events_only` mode**, the v4 default this stack runs; migrate them to observation-level ones
([upgrade guide](https://langfuse.com/faq/all/llm-as-a-judge-migration)).

### One-time setup (self-hosted): an Anthropic LLM connection
1. **Add a judge model** — UI → **Settings → LLM Connections** → add an **Anthropic** key
   (adapter `anthropic`). The model must support structured output; `claude-haiku-4-5`
   (the lab's model) does.
2. That key lives in Langfuse (Postgres, encrypted), *not* in `_base/.env` — `ANTHROPIC_API_KEY`
   in `_base/.env` is what the lab *scripts* use. The **worker** container, not your script,
   calls the provider, so it needs network egress to it.

### Create an observation-level evaluator (UI)
1. UI → **Evaluators** → **New evaluator**; pick a template (e.g. Helpfulness) or start blank.
2. Choose the judge model (or the project default) and edit the prompt with `{{input}}`,
   `{{output}}` (and `{{ground_truth}}` for experiments).
3. **Map variables** by clicking the observation field each one reads (input, output,
   metadata, tool calls), and pick the score type (numeric, boolean, categorical).
4. **Test** on a sample observation, then **save**.
5. Create a **rule**: filters that select observations (for example *Is Root Observation* and
   name `support-request`), a sampling %, and this evaluator. New matching observations are
   judged within seconds; the score appears on the observation and under **Scores**.

### Programmatic setup (stable API)
The same three objects exist in the public API: `PUT /api/public/llm-connections`,
`POST /api/public/v2/evaluators`, `POST /api/public/v2/evaluation-rules` (request shapes in
the [OpenAPI spec](https://cloud.langfuse.com/generated/api/openapi.yml)). From the repository
root, with `jq`; the Anthropic key is read from `_base/.env` and sent on stdin, never on a
command line:

```bash
# <managed-evaluator>
H=http://localhost:3000
AUTH="$(grep '^LANGFUSE_PUBLIC_KEY=' _base/.env | cut -d= -f2-):$(grep '^LANGFUSE_SECRET_KEY=' _base/.env | cut -d= -f2-)"
api() { curl -sS -u "$AUTH" -H 'Content-Type: application/json' -X "$1" "$H$2" -d @-; }

# 1) the Anthropic LLM connection
jq -n --arg k "$(grep '^ANTHROPIC_API_KEY=' _base/.env | cut -d= -f2-)" \
  '{provider:"anthropic", adapter:"anthropic", secretKey:$k, withDefaultModels:true}' \
  | api PUT /api/public/llm-connections | jq '{id, provider, adapter, withDefaultModels}'

# 2) the evaluator: judge the root observation's input and output, score 0..1
EVALUATOR=$(jq -n '{
    name:"support-answer-helpfulness", type:"llm_as_judge",
    prompt:"You grade a customer-support assistant.\nQuestion: {{input}}\nAnswer: {{output}}\nScore from 0 to 1 how well the answer addresses the question.",
    modelConfig:{provider:"anthropic", model:"claude-haiku-4-5"},
    variableMapping:[{variable:"input",source:"input"},{variable:"output",source:"output"}],
    outputDefinition:{dataType:"NUMERIC", minValue:0, maxValue:1,
      scoreReasoningInstructions:"One sentence.",
      scoreValueInstructions:"0 = off-topic, 1 = fully addresses the question."}}' \
  | api POST /api/public/v2/evaluators | jq -r .id)

# 3) the rule: root observations named support-request, every one of them
jq -n --arg e "$EVALUATOR" '{
    name:"judge support-request roots", enabled:true, sampling:1,
    filter:[{type:"boolean", column:"isRootObservation", operator:"=", value:true},
            {type:"stringOptions", column:"name", operator:"any of", value:["support-request"]}],
    evaluatorAssignments:[{evaluatorId:$e}]}' \
  | api POST /api/public/v2/evaluation-rules | jq '{id, enabled, filter}'
# </managed-evaluator>
```

A rule judges observations that arrive **after** it exists, so seed some more traces next
(`python 01-seed-traces.py 5`) and look at the scores a few seconds later.

### Where the scores land
On the **observation** (the root, here) — `scores.observation_id` and `scores.trace_id`
are both set — and in ClickHouse `scores` with **`source = 'EVAL'`**; lab 07 breaks scores
down by source (API / EVAL / ANNOTATION). Every judge call is itself traced: filter the
Observations table for the environment `langfuse-llm-as-a-judge` to debug a run
([LLM-as-a-Judge](https://langfuse.com/docs/evaluation/evaluation-methods/llm-as-a-judge)).

### Sources
[LLM-as-a-Judge](https://langfuse.com/docs/evaluation/evaluation-methods/llm-as-a-judge) ·
[LLM Connections](https://langfuse.com/docs/administration/llm-connection) ·
[Upgrade trace-level evaluators](https://langfuse.com/faq/all/llm-as-a-judge-migration) ·
[Anthropic integration](https://langfuse.com/integrations/model-providers/anthropic)

---

## 한국어

### 무엇인가
**evaluator**(판정 프롬프트·`{{변수}}`·판정 모델·score 정의)와 **rule**(어떤 들어오는
observation을 얼마나 판정할지)을 Langfuse **worker**가 실행합니다. 매 실행은 **LLM
connection**으로 판정 모델을 호출하고, 매칭된 observation에 **score(source `EVAL`)** 를
기록합니다. OSS 기능(라이선스 불필요)이지만 판정 모델 설정이 필요합니다.

Langfuse v4에서 대상은 **observation**입니다. trace는 곧 루트 observation이므로, 요청 전체를
판정하려면 루트를 대상으로 하세요(rule 필터 *Is Root Observation*). evaluator는 그 observation
하나의 input/output만 보며 자식은 보지 않습니다. 예전 **trace 수준** evaluator(그리고 legacy
dataset evaluator)는 *Legacy*로 표시되며, 이 스택의 v4 기본값인 **`events_only` 모드에서는 더 이상
결과를 내지 않습니다**. observation 수준으로 옮기세요
([업그레이드 가이드](https://langfuse.com/faq/all/llm-as-a-judge-migration)).

### 최초 설정 (self-hosted): Anthropic LLM connection
1. **판정 모델 등록** — UI → **Settings → LLM Connections** 에서 **Anthropic** 키 추가(adapter
   `anthropic`). structured output을 지원하는 모델이어야 하며, 이 랩의 `claude-haiku-4-5`는 지원합니다.
2. 이 키는 Langfuse(Postgres, 암호화)에 저장되며 `_base/.env`가 아닙니다. `_base/.env`의
   `ANTHROPIC_API_KEY`는 랩 *스크립트*가 쓰는 것입니다. 공급자를 호출하는 쪽은 스크립트가 아니라
   **worker** 컨테이너이므로, worker에서 공급자로 나가는 네트워크가 필요합니다.

### observation 수준 evaluator 생성 (UI)
1. UI → **Evaluators** → **New evaluator**; 템플릿(예: Helpfulness)을 고르거나 빈 상태로 시작.
2. 판정 모델(또는 프로젝트 기본값)을 고르고 프롬프트를 `{{input}}`, `{{output}}`
   (실험에서는 `{{ground_truth}}`)로 작성.
3. 각 변수가 읽을 observation 필드(input, output, metadata, tool calls)를 클릭해 **매핑**하고, score
   유형(수치·불리언·범주형)을 고릅니다.
4. 샘플 observation으로 **테스트** 후 **저장**.
5. **rule** 생성: observation을 고르는 필터(예: *Is Root Observation* + 이름 `support-request`),
   샘플링 %, 그리고 이 evaluator. 이후 매칭되는 새 observation은 수 초 안에 판정되고, score는
   observation과 **Scores**에 나타납니다.

### 프로그램적 설정 (stable API)
같은 세 객체가 공개 API에도 있습니다: `PUT /api/public/llm-connections`,
`POST /api/public/v2/evaluators`, `POST /api/public/v2/evaluation-rules` (요청 형식은
[OpenAPI 스펙](https://cloud.langfuse.com/generated/api/openapi.yml)). 저장소 루트에서 `jq`와 함께
실행합니다. Anthropic 키는 `_base/.env`에서 읽어 명령줄이 아닌 stdin으로 보냅니다. 명령은 위 영어
섹션의 블록과 동일합니다.

rule은 **생성 이후** 들어오는 observation만 판정하므로, 이어서 trace를 더 시드하고
(`python 01-seed-traces.py 5`) 몇 초 뒤 score를 확인하세요.

### 점수 저장 위치
**observation**(여기서는 루트)에 저장됩니다 — `scores.observation_id`와 `scores.trace_id`가 모두
채워집니다. ClickHouse `scores` 테이블에는 **`source = 'EVAL'`** 로 들어가며, 랩 07에서 source별
(API / EVAL / ANNOTATION)로 분해합니다. 판정 호출 자체도 trace로 남습니다. Observations 표를
환경 `langfuse-llm-as-a-judge`로 필터링해 디버깅하세요
([LLM-as-a-Judge](https://langfuse.com/docs/evaluation/evaluation-methods/llm-as-a-judge)).

### 출처
[LLM-as-a-Judge](https://langfuse.com/docs/evaluation/evaluation-methods/llm-as-a-judge) ·
[LLM Connections](https://langfuse.com/docs/administration/llm-connection) ·
[trace 수준 evaluator 업그레이드](https://langfuse.com/faq/all/llm-as-a-judge-migration) ·
[Anthropic 연동](https://langfuse.com/integrations/model-providers/anthropic)
