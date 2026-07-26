# 05 — Managed LLM-as-a-Judge (companion guide)

[English](#english) · [한국어](#한국어)

`05-llm-as-a-judge.py` runs a judge **as an experiment evaluator** (works offline).
This guide covers Langfuse's **managed** LLM-as-a-judge: pre-built evaluators that
Langfuse runs *for you*, continuously, on production traces or on dataset runs.

---

## English

### What it is
A library of maintained evaluator templates — **Hallucination, Context-Relevance,
Toxicity, Helpfulness** (plus Ragas) — that Langfuse executes with a judge model
and writes back as **scores** (source `EVAL`) on the matched traces/observations.
This is OSS (no license key), but it needs a judge model configured.

### One-time setup (self-hosted)
1. **Add a judge model** — UI → **Settings → LLM Connections** → add an OpenAI or
   Anthropic key. The model **must support structured output** (e.g. `gpt-4o-mini`,
   `gpt-4o`) — the judge returns structured verdicts.
2. That key lives in Langfuse (Postgres, encrypted), *not* in this lab's `.env`.

### Create a managed evaluator (UI — recommended)
1. UI → **Evaluators** (a.k.a. Evaluation → LLM-as-a-judge) → **+ New evaluator**.
2. Pick a template (e.g. **Hallucination**) and the judge model.
3. Choose a **target**:
   - **Live production traces** — with an optional **sampling %** and filters.
   - **Dataset runs** — score the `prompt-v1` / `prompt-v2` runs from lab 04.
4. **Map variables** — bind the template's `{{input}}`, `{{output}}`,
   `{{ground_truth}}` to trace fields (input / output / expected_output). Use the
   live preview to confirm the mapping.
5. Save. New matching traces/runs get judged automatically; scores appear on each
   trace and in aggregate under **Scores**.

### Programmatic setup (optional, ⚠️ unstable API)
Langfuse exposes Evaluator / Evaluation-Rule endpoints, but they are explicitly
**unstable** while the eval data model is being redesigned. Discover the current
contract before scripting against it:

```bash
export LANGFUSE_HOST=http://localhost:3000
export LANGFUSE_PUBLIC_KEY=pk-lf-...   # from this lab's .env
export LANGFUSE_SECRET_KEY=sk-lf-...
npx langfuse-cli api __schema | grep -i eval     # find eval resources
npx langfuse-cli api <resource> --help           # inspect actions/args
```

Prefer the UI for a workshop; use the CLI only if you must automate.

### Where the scores land
On the trace/observation, and in ClickHouse `scores` with **`source = 'EVAL'`** —
lab 07 breaks scores down by source (API / EVAL / ANNOTATION).

---

## 한국어

### 무엇인가
Langfuse가 유지관리하는 평가 템플릿 라이브러리 — **Hallucination · Context-Relevance ·
Toxicity · Helpfulness** (+ Ragas) — 를 판정 모델로 실행해, 매칭된 trace/observation에
**score(source `EVAL`)** 로 기록합니다. OSS 기능(라이선스 불필요)이지만 판정 모델 설정이
필요합니다.

### 최초 설정 (self-hosted)
1. **판정 모델 등록** — UI → **Settings → LLM Connections** 에서 OpenAI/Anthropic 키 추가.
   **structured output 지원 모델** 필수(`gpt-4o-mini`, `gpt-4o` 등).
2. 이 키는 Langfuse(Postgres, 암호화)에 저장되며 이 랩의 `.env`가 아닙니다.

### 관리형 평가자 생성 (UI 권장)
1. UI → **Evaluators** → **+ New evaluator**.
2. 템플릿(예: **Hallucination**)과 판정 모델 선택.
3. **타깃** 선택: **운영 trace**(샘플링 % + 필터) 또는 **dataset run**(랩 04의 v1/v2 run).
4. **변수 매핑**: 템플릿의 `{{input}}`/`{{output}}`/`{{ground_truth}}` 를 trace 필드에 연결
   (라이브 프리뷰로 확인).
5. 저장 → 이후 매칭되는 trace/run이 자동 채점되고, 각 trace와 **Scores** 집계에 표시됩니다.

### 프로그램적 설정 (선택, ⚠️ 불안정 API)
Evaluator/Evaluation-Rule 엔드포인트는 **unstable**로 명시되어 있습니다. 스크립트 작성 전
현재 계약을 먼저 확인하세요:

```bash
npx langfuse-cli api __schema | grep -i eval
npx langfuse-cli api <resource> --help
```

워크샵에서는 UI를 권장합니다.

### 점수 저장 위치
trace/observation 및 ClickHouse `scores` 테이블(**`source = 'EVAL'`**). 랩 07에서 source별
(API / EVAL / ANNOTATION)로 분해합니다.
