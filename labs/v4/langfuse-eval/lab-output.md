# Evaluating Models in Langfuse — Blog Source & Execution Log

> Working material for a tech blog titled **"Evaluating Models in Langfuse"**.
> It bundles the narrative, the code and the **real execution logs** captured while
> verifying [`labs/v4/langfuse-eval/`](./README.md).
>
> **Verified environment (2026-10-08; the run's UTC timestamps are 2026-10-08T05:5x):**
> - Langfuse server **v4.53.0**
> - Python SDK `langfuse` **4.17.0** on Python 3.12.14
> - **ClickHouse 26.8.19.9**
> - The shared self-hosted Docker stack in [`_base/`](../../../_base/README.md)
>
> Every step ran **offline** (deterministic simulation). Steps 04 and 05 also ran with
> **real model calls to Anthropic `claude-haiku-4-5`**, and step 05's managed evaluator used an
> Anthropic LLM connection. Both modes are shown below.

---

## 1. The hook

Most Langfuse tutorials stop at "send a trace". But the reason teams adopt an LLM
observability platform is the next question: **is my app actually any good, and did my
last change make it better or worse?**

Langfuse answers that with a tight loop of product features: **prompt management →
datasets → experiments → LLM-as-a-judge → human annotation**. Because it is self-hosted
on **ClickHouse**, every quality signal it produces is queryable with SQL.

This post walks that loop end to end on a self-hosted instance, then drops into the
ClickHouse backend to show where the numbers physically live.

> Everything except the optional model calls is **OSS (MIT)**, with no licence key. Without an
> `ANTHROPIC_API_KEY` the whole loop runs offline with deterministic code evaluators.

---

## 2. The quality loop

```
   (02) Prompt Mgmt ──► (03) Dataset ──► (04) Experiment ──► (05) LLM-judge
   version · label       golden Q&A       prompt v1 vs v2      grade correctness
        ▲                                       │                    │
        │                                       ▼                    ▼
        └────────────── (06) Annotation ◄── human review ──► (07) scores in ClickHouse
                         score configs + queue                 API · EVAL · ANNOTATION
```

The punchline for a data-platform audience: **user feedback, code evaluators, the LLM
judge and human annotations all converge in one ClickHouse table, `scores`, told apart by
a `source` column.** That single table is what makes cross-cutting quality analytics
(agreement, drift, A/B) a plain `SELECT`.

---

## 3. Setup

The lab runs on the shared stack in `_base/`, the same one `labs/langfuse-ee` uses:

```bash
# from the repository root
python3.12 -m venv .venv-v4 && .venv-v4/bin/pip install -r _base/v4/requirements.txt   # Python 3.10+
_base/bin/up.sh v4         # postgres · clickhouse · redis · minio · web · worker
#    → http://localhost:3000   login admin@example.com / workshop-admin-pw
#    → project "LLM Observability"  (public key pk-lf-workshop-public)
_base/bin/check.sh v4      # containers, ClickHouse migrations, SDK keys
# optional: ANTHROPIC_API_KEY=… in _base/.env → real model calls
```

A small `_common.py` centralizes the boring parts:
- `.env` loading
- the client
- a REST helper for endpoints without an SDK method
- the shared Q&A knowledge base
- the one optional real-model call

```python
def client():
    from langfuse import Langfuse, get_client
    Langfuse(base_url=..., public_key=..., secret_key=...)   # SDK v4: base_url (host= is deprecated)
    lf = get_client()
    if not lf.auth_check():
        raise SystemExit("Auth failed — is the stack up and are LANGFUSE_* keys set?")
    return lf

def ask_claude(*, system, user, model, max_tokens):         # only when ANTHROPIC_API_KEY is set
    AnthropicInstrumentor().instrument()                    # once: traces the call as a GENERATION
    resp = anthropic.Anthropic(timeout=60.0).messages.create(
        model=model, max_tokens=max_tokens, system=system,
        messages=[{"role": "user", "content": user}])
    ...
```

---

## 4. Step 01 — seed traces to evaluate

You can't evaluate an empty project. The shared trace generator (a customer-support RAG
assistant) seeds about 20 nested traces with token usage, tags and user-feedback scores:

```bash
ANTHROPIC_API_KEY= python 01-seed-traces.py 20
```

```text
→ Seeding 20 traces with the shared trace generator:
  _base/v4/seed_traces.py
✓ Connected. Generating 20 traces (offline / simulated)…
  …10/20 traces
  …20/20 traces
✓ Done. Open http://localhost:3000 → Tracing → Observations.
```

---

## 5. Step 02 — Prompt management

Store the system prompt **in Langfuse, not in code**:
- Create **v1** (terse) and **v2** (guard-railed).
- Creating v2 with the `production` label instantly *deploys* it: the label moves, while v1 stays reachable by version number.
- Fetch by label and fill the variables with `.compile()`.
- **Link** the prompt to a generation with `prompt=`, so the UI can attribute performance to that version.

```python
lf.create_prompt(name="support-system", type="text",
    prompt="You are a {{tone}} customer-support assistant. "
           "Answer the user's question in one short sentence.",
    labels=["production"], config={"model": "claude-haiku-4-5", "temperature": 0.2})

# v2 — creating with `production` MOVES the label here (a deploy); `latest` too.
lf.create_prompt(name="support-system", type="text",
    prompt="You are a {{tone}} customer-support assistant. Answer in one short "
           "sentence using only verified product facts. If you are unsure, say you "
           "will escalate to a human — never invent policy.",
    labels=["production", "latest"], config={"model": "claude-haiku-4-5", "temperature": 0.2})

prod = lf.get_prompt("support-system")                 # → v2 (production)
with lf.start_as_current_observation(as_type="generation", name="demo",
                                     model="claude-haiku-4-5", prompt=prod) as gen:  # ← link
    gen.update(output="…", usage_details={"input": 42, "output": 18})            # v4: input/output
```

```text
✓ created support-system v1  (label: production)
✓ created support-system v2  (labels: production, latest) — production now → v2
✓ created support-system-chat  (type: chat)
— production (v2) compiled —
   You are a friendly customer-support assistant. Answer in one short sentence using
   only verified product facts. If you are unsure, say you will escalate to a human
   — never invent policy.
— version 1 compiled —
   You are a friendly customer-support assistant. Answer the user's question in one
   short sentence.
```

> **Where it lives:** prompts are in **Postgres** (OLTP). You won't find them in ClickHouse.

---

## 6. Step 03 — Datasets (the golden test set)

A dataset is a reusable set of test cases: `input` plus `expected_output`. Passing a
stable `id=` makes re-runs **idempotent**: they upsert instead of duplicating.

```python
lf.create_dataset(name="support-golden-qa", description="…")
for i, (question, answer) in enumerate(SUPPORT_QA):
    lf.create_dataset_item(dataset_name="support-golden-qa", id=f"golden-{i:02d}",
                           input={"question": question}, expected_output=answer)
```

```text
✓ dataset 'support-golden-qa' ready
✓ upserted 10 items (ids golden-00 … golden-09)
```

---

## 7. Step 04 — Experiments (the heart)

`dataset.run_experiment(name, task, evaluators=[…])` runs a task over every item,
traces each run automatically and scores it. We run it **twice**, prompt v1 against v2,
with three **code evaluators**: `keyword-recall`, `length-ok` and `answered`.

SDK v4 has no `update_current_trace()`. The variant tag goes on with
`propagate_attributes()`, wrapped around `run_experiment()` rather than the task. That way it
also reaches the root `experiment-item-run` observation, the row that identifies the trace.

```python
def run(dataset, name, description, prompt_obj, variant):
    with propagate_attributes(tags=[f"variant:{variant}", "eval-experiment"],   # ← for the CH A/B
                              metadata={"variant": variant}):
        return dataset.run_experiment(name=name, description=description,
                                      task=make_task(prompt_obj, variant), evaluators=EVALUATORS)

def make_task(prompt_obj, variant):
    system_prompt = prompt_obj.compile(tone="friendly")
    def task(*, item, **kwargs):
        if use_anthropic():    # the instrumented client creates the GENERATION itself
            with propagate_attributes(prompt=prompt_obj):
                return generate_answer(system_prompt=system_prompt, question=item.input["question"], ...)
        with lf.start_as_current_observation(as_type="generation", name="answer-generation",
                                             model=MODEL, prompt=prompt_obj) as gen:   # offline
            answer = generate_answer(...)
            gen.update(output=answer, usage_details={"input": ..., "output": ...})
        return answer
    return task
```

Offline (`ANTHROPIC_API_KEY` empty) — the simulation answers from the KB for v2 and deflects for v1, by construction:

```text
🧪 Experiment: prompt-v1
10 items
Average Scores:
  • answered: 0.000
  • length-ok: 1.000
  • keyword-recall: 0.000
🧪 Experiment: prompt-v2
10 items
Average Scores:
  • answered: 1.000
  • length-ok: 1.000
  • keyword-recall: 1.000
```

Real model (`claude-haiku-4-5`):

```text
Running experiments over 'support-golden-qa' (REAL Anthropic claude-haiku-4-5)…
🧪 Experiment: prompt-v1
10 items
Average Scores:
  • keyword-recall: 0.283
  • length-ok: 1.000
  • answered: 1.000
🧪 Experiment: prompt-v2
10 items
Average Scores:
  • keyword-recall: 0.135
  • length-ok: 1.000
  • answered: 1.000
```

**The real run disagrees with the simulation**, and that is the point of running it. A real
model answers both prompts, and the guard-railed v2 ("if you are unsure, say you will
escalate") gives *less* of the reference wording than the terse v1. In the UI,
**Datasets → Runs** shows the runs side by side.

---

## 8. Step 05 — LLM-as-a-judge (hybrid)

A model grades the output. Offline, the evaluator applies a deterministic rubric. With
`ANTHROPIC_API_KEY` set, it makes a real grading call, which is traced as a GENERATION
under the evaluator's span:

```python
def llm_judge(*, input, output, expected_output, **kwargs):
    if use_anthropic():
        text = ask_claude(system="You are a strict grader for a customer-support assistant.",
                          user=f"Question: …\nReference answer: …\nCandidate answer: …\n\n"
                               "Score how correct and grounded the candidate is, from 0.0 to 1.0. "
                               "Reply with ONLY the number.",
                          model=JUDGE_MODEL, max_tokens=256)
        return Evaluation(name="llm-judge-correctness", value=..., comment=f"graded by {JUDGE_MODEL}")
    # offline: token overlap with the reference, zeroed on deflections
    return Evaluation(name="llm-judge-correctness", value=overlap)
```

```text
offline:  judge-prompt-v1 → llm-judge-correctness: 0.000   judge-prompt-v2 → 1.000
real:     judge-prompt-v1 → llm-judge-correctness: 0.415   judge-prompt-v2 → 0.200
```

The real judge agrees with the real keyword evaluator: on this golden set the
guard-railed prompt costs correctness.

**Managed evaluators.** Langfuse also runs evaluators *continuously* on incoming
observations and writes `source = 'EVAL'`. On v4 these are **observation-level**
evaluators; trace-level ones are Legacy and stop running in `events_only` mode.
[`05-llm-as-a-judge.md`](05-llm-as-a-judge.md) sets one up through the public API. It needs
three pieces:
- an Anthropic LLM connection
- an evaluator that judges a root observation's input and output
- a rule for root observations named `support-request`

Seeding five more traces then produced:

```text
EVAL scores: 5 (after 10 s of polling)
source  name                        n  avg
EVAL    support-answer-helpfulness  5  0.95
```

This run did not query the judge's own observations in ClickHouse (the evaluator execution span and its model calls), so no per-call cost is shown for the managed evaluator.

---

## 9. Step 06 — Annotation queues (human-in-the-loop)

Define **score configs** (the review dimensions), a **queue** bound to them, and enqueue
items. All of this goes through the public REST API with Basic auth; the Python SDK has no
helper for these. Two things changed on v4:
- `/api/public/v2/scores` answers 404, and `/v3/scores` returns the trace linkage only when you ask for the `subject` field group (seen on 2026-10-02, not re-tested; see §11 note 5).
- Queue items are the trace's **root observation**, enqueued as `OBSERVATION`.

```python
quality_id = api("POST", "/api/public/score-configs",
    {"name": "answer-quality", "dataType": "CATEGORICAL",
     "categories": [{"label": "good", "value": 1}, {"label": "ok", "value": 0.5},
                    {"label": "bad", "value": 0}]})["id"]
correct_id = api("POST", "/api/public/score-configs",
    {"name": "factually-correct", "dataType": "BOOLEAN"})["id"]
queue_id = api("POST", "/api/public/annotation-queues",
    {"name": "human-review", "scoreConfigIds": [quality_id, correct_id]})["id"]

# enqueue traces that already have user feedback (so signals co-occur — see §10.5)
scored = api("GET", "/api/public/v3/scores?name=user-thumbs&limit=25&fields=subject")["data"]
trace_ids = list(dict.fromkeys(s["subject"]["id"] for s in scored
                               if s["subject"]["kind"] == "trace"))[:8]
for tid in trace_ids:
    api("POST", f"/api/public/annotation-queues/{queue_id}/items",
        {"objectId": root_observation_id(tid), "objectType": "OBSERVATION"})
```

```text
✓ score configs: answer-quality=107f0286… factually-correct=b72dd514…
✓ queue 'human-review' = cmuz4g77o000oqg07bj7tfnc2
✓ enqueued 8 traces (as their root observations) for human review
✓ wrote demo review scores on 8 traces
```

Real reviewers score in the keyboard-driven **UI → Annotations** queue; those scores
arrive with `source = 'ANNOTATION'`.

---

## 10. Step 07 — Every signal, unified in ClickHouse (the payoff)

Now the SA moment: plain SQL on `scores`, joined to the v4 events table when a query needs
trace context. Langfuse tables are `ReplacingMergeTree`, so read them with `FINAL` +
`WHERE is_deleted = 0`. Give step 06 about ten seconds before this step, because scores
ingest asynchronously.

```bash
docker exec -i langfuse-hols-v4-clickhouse-1 clickhouse-client \
  -u clickhouse --password clickhouse --multiquery < 07-scores-in-clickhouse.sql
```

The `scores` schema (abridged `DESCRIBE`):

```
trace_id  Nullable(String)   observation_id Nullable(String)   name  String   value Float64
source    String             data_type  String                 string_value Nullable(String)
dataset_run_id Nullable(String)   queue_id Nullable(String)   is_deleted UInt8   timestamp DateTime64(3)
```

### 10.1 The unified score model — every signal, by source & name

```sql
SELECT source, name, any(data_type) AS data_type, count() AS n, round(avg(value),3) AS avg_value
FROM scores FINAL WHERE is_deleted = 0
GROUP BY source, name ORDER BY source, name;
```

```text
source  name                        data_type  n    avg_value
API     answered                    NUMERIC    40   0.75
API     hallucination-check         NUMERIC    23   0.787
API     human-answer-quality        NUMERIC     8   0.875
API     human-factually-correct     BOOLEAN     8   0.75
API     keyword-recall              NUMERIC    40   0.354
API     length-ok                   NUMERIC    40   1
API     llm-judge-correctness       NUMERIC    40   0.404
API     user-thumbs                 BOOLEAN    25   0.8
EVAL    support-answer-helpfulness  NUMERIC     5   0.95   ← the managed evaluator (step 05)
```

**Three provenances in one table.**
- Experiment evaluators and SDK scores are `source = API`.
- The managed evaluator wrote `EVAL`.
- UI annotations would write `ANNOTATION`.

This run started from a purged stack, so only this lab's own scores appear. There are no `pii-demo` rows from the neighbouring `langfuse-ee` lab.

### 10.2 Volume by data type

```text
NUMERIC   196
BOOLEAN    33
```

### 10.3 Numeric distribution per metric (p50/p90)

```text
name                        n    mean   p50    p90
answered                    40   0.75   1      1
hallucination-check         23   0.787  0.74   0.948
human-answer-quality         8   0.875  1      1
keyword-recall              40   0.354  0.143  1
length-ok                   40   1      1      1
llm-judge-correctness       40   0.404  0.2    1
support-answer-helpfulness   5   0.95   1      1
```

### 10.4 Experiment A/B — reconstructed in ClickHouse

Evaluator scores did not carry the dataset-run id in ClickHouse on the 2026-10-02 run (0 of 40
experiment scores had `dataset_run_id`, although all 40 carried `observation_id`); this was not
re-queried in the later runs. Step 04 tagged each experiment's root row with its variant, so a
scores → root-row join reconstructs the A/B (the result below is from 2026-10-08):

```sql
SELECT multiIf(has(e.tags,'variant:v1'),'prompt-v1',
               has(e.tags,'variant:v2'),'prompt-v2','other') AS variant,
       s.name AS metric, count() AS n, round(avg(s.value),3) AS avg_value
FROM scores AS s FINAL
INNER JOIN (SELECT trace_id, tags FROM events_core FINAL
            WHERE is_deleted = 0 AND is_app_root AND has(tags,'eval-experiment')) AS e
        ON s.trace_id = e.trace_id
WHERE s.is_deleted = 0
  AND s.name IN ('keyword-recall','answered','llm-judge-correctness')
GROUP BY variant, metric ORDER BY metric, variant;
```

```text
variant     metric                 n    avg_value
prompt-v1   answered               20   0.5
prompt-v2   answered               20   1
prompt-v1   keyword-recall         20   0.141
prompt-v2   keyword-recall         20   0.568
prompt-v1   llm-judge-correctness  20   0.208
prompt-v2   llm-judge-correctness  20   0.6
```

**Read it as two runs, not one.** Each `n = 20` is the offline run (10) plus the real run
(10) of the same experiment.

| | keyword-recall v1 → v2 | judge v1 → v2 |
|---|---|---|
| Offline simulation | 0 → 1 | 0 → 1 |
| Real `claude-haiku-4-5` | 0.283 → 0.135 | 0.415 → 0.200 |

To keep the two apart in ClickHouse, add the run to the `GROUP BY`. v4's event tables have
`experiment_id` / `experiment_name` columns (see the schema in `langfuse-ee` lab 03), a second
key you get without tagging anything. This run did not query them. It is still a single
`GROUP BY` either way.

### 10.5 Per-trace agreement of co-occurring signals

Pivot to one row per trace: user sentiment against the automated hallucination check
against the human review, all on the same seed traces.

```text
trace_id                          user_thumbs  halluc_check  human_quality
038dcc52e305de37481c5700ac4d6787       1           0.86           1
07a40dd308e35c1b3cef579566d69c18       0           \N             1       ← error trace: no check
0c3a5b827f22345c2a6f5366b7789014       1           0.88           1
214f7c0ccd81006fa0aa2791f0c2d7de       1           0.71           1
c8778a9452e1bfb0273e794f883c63b0       1           0.95           1
e9893e72b23a7a874db33032ecb25e56       1           0.84           1
eb2b30d9e78c310586378cf8b94e173f       1           0.94           0.5
ff60fd6a4794e9cff05ceb1e6b9d3cca       0           \N             0.5     ← error trace: no check
```

The two `\N` rows are error traces. For those the seeder writes a thumbs-down and no
`hallucination-check`. The query pivots with `anyIfOrNull`, so a missing score shows as
`NULL` (`\N`). Plain `anyIf` would return the `Float64` default `0` there, which reads like a
failed check ([#46](https://github.com/litkhai/langfuse-hols/issues/46)).

Of the eight traces, `ff60fd6a…` is the row you want surfaced: the user gave a thumbs-down
and the human graded it `0.5`. On `eb2b30d9…` the reviewer was less satisfied (`0.5`) than
the user and the automated check (`0.94`). That cross-signal view is the analysis the UI
doesn't give you and ClickHouse does.

### 10.6 Daily trend

```text
day          n_scores  avg_llm_judge
2026-10-08   40        0.404          (UTC)
```

---

## 11. Field notes — what the SDK actually does (blog-worthy gotchas)

These are the non-obvious behaviours we hit and had to design around: good "here's what
the docs don't tell you" material. Notes 1, 2, 4 and 6 were re-observed in the 2026-10-08 run
(Langfuse 4.53.0, SDK 4.17.0). Notes 3, 5, 7 and 8 contain claims from the 2026-10-02 run
(Langfuse 4.48.0, SDK 4.16.0) that this run did not measure; those claims are marked.

1. **Simulation and a real model can disagree — run both.** Offline, the guard-railed
   prompt wins on every metric by construction. With `claude-haiku-4-5` it *lost*:
   keyword-recall 0.283 → 0.135, and the judge 0.415 → 0.200. Two independent
   evaluators agree that the "escalate if unsure" wording costs correctness on this set.

2. **Experiment scores are `source = API`; managed evaluators write `EVAL`.** Scores from
   `run_experiment` evaluators, including an in-code LLM judge, land as `API`. The
   managed observation-level evaluator wrote `EVAL`. UI annotations write `ANNOTATION`.

3. **Scores attach to observations now.** On v4, experiment scores join to the root row by
   `trace_id`, and the A/B join in §10.4 returned n = 20 per variant and metric on 2026-10-08.
   The 2026-10-02 run also found `observation_id` set and `dataset_run_id` empty on all 40
   experiment scores; that was not re-queried in the later runs. Reconstruct an A/B by the root
   row's tags, or by `experiment_id` on the event rows.

4. **Tag around `run_experiment()`, not inside the task.** `propagate_attributes()` inside
   the task starts one level below the root `experiment-item-run` observation. The A/B
   join reads the root row, so wrap the experiment call instead.

5. **v4 REST changes.** Step 06 ran clean on 2026-10-08 using the calls below. The 404s and the
   missing linkage were observed on 2026-10-02 and not re-tested.
   - `/api/public/v2/scores` and `/api/public/scores` answer 404 (2026-10-02).
   - `/v3/scores` leaves the trace linkage out unless you request `fields=subject` (2026-10-02).
     Step 06 requests it.
   - Annotation-queue items for a trace are its root observation, enqueued as `OBSERVATION`.

6. **Scores ingest asynchronously.** They flow SDK → worker → ClickHouse. Give it about ten
   seconds after step 06 before querying `scores` in step 07; poll rather than assume.

7. **Trace names are not unique across labs on a shared stack.** Select traces by a score
   they carry (`/v3/scores?name=user-thumbs`), not by name. The neighbouring lab's PII
   traces share the `support-request` name. This was seen on 2026-10-02; the 2026-10-08 run
   started from a purged stack, so it was not re-observed.

8. **Two databases, two jobs.** Prompts, datasets and annotation queues live in
   **Postgres**. Observations (`events_full` / `events_core`) and **scores** live in
   **ClickHouse**. Step 07 here read scores and the events tables from ClickHouse; the
   Postgres side was not queried on 2026-10-08 (the `langfuse-ee` run did show prompts there).

9. **`config_id` binding is strictly typed** (seen on SDK 3.7.0; not re-tested on v4).
   A score whose `data_type` doesn't match its config's was dropped at ingestion. The lab
   therefore writes its demo review scores unbound.

---

## 12. Verification table

| Step | Result |
|---|---|
| `01` seed | 20 traces ingested through the shared generator |
| `02` prompts | v1 + v2 + chat; `production` label moved to v2; compile + `prompt=` link OK |
| `03` dataset | 10 items upserted (`golden-00…09`), idempotent |
| `04` experiments | Offline: v1 `answered 0 / keyword-recall 0` → v2 `1 / 1`. Real `claude-haiku-4-5`: keyword-recall v1 0.283 → v2 0.135 |
| `05` LLM-judge | Offline `0 → 1`. Real judge `0.415 → 0.200`. Managed observation-level evaluator: 5 `EVAL` scores, avg 0.95 |
| `06` annotation | 2 score configs + `human-review` queue + 8 root observations enqueued + demo scores |
| `07` ClickHouse | unified model (API + EVAL), A/B via root-row join, per-trace agreement, daily trend |

Environment: Langfuse v4.53.0 · SDK `langfuse` 4.17.0 · ClickHouse 26.8.19.9 · offline and
real (`claude-haiku-4-5`). This lab's real-call cost was not summed on 2026-10-08. The 5 real
calls of `langfuse-ee` lab 02 were priced by Langfuse at $0.001278
([lab-output](../langfuse-ee/lab-output.md)).

---

## 13. Suggested blog outline

1. **Why evaluation is the real reason to run an LLM observability platform** (§1)
2. **The quality loop in one diagram** (§2)
3. **Prompts as versioned, deployable artifacts** (§5)
4. **Datasets + experiments: catching a regression before prod** (§6–7). Lead with the real run: the guard-rail that looked like a win offline.
5. **Judging at scale: code evaluators, LLM-as-a-judge and managed evaluators** (§8)
6. **Humans in the loop** (§9)
7. **The ClickHouse payoff: one `scores` table, every signal** (§10). This is the differentiator for a ClickHouse audience; lead with §10.4 and §10.5.
8. **Field notes / gotchas** (§11)
9. **Try it yourself.** Link the lab, and note that it is OSS and runs offline.

**Recommended hero visuals:**
- The §10.4 two-runs table: offline 0 → 1, real 0.283 → 0.135.
- The §10.5 agreement table, with the row where the user and the reviewer both flag a weak answer (`ff60fd6a…`).

---

*Source lab: [`labs/v4/langfuse-eval/`](./README.md) · Governance sibling:
[`labs/v4/langfuse-ee/`](../langfuse-ee/README.md) · Author: Ken Lee (ClickHouse SA).*
