# Evaluating Models in Langfuse — Blog Source & Execution Log

> Working material for a tech blog titled **"Evaluating Models in Langfuse"**.
> It bundles the narrative, the code, and the **real execution logs** captured while
> building & verifying [`labs/v3/langfuse-eval/`](./README.md).
>
> **Verified environment (2026-10-08):** Langfuse server **v3.225.11** · Python SDK
> `langfuse` **3.15.0** · **ClickHouse 26.8.19.9** (the track pin in `_base/v3/versions.env`)
> · Python 3.12.14 · self-hosted Docker stack (web · worker · postgres · clickhouse · redis
> · minio). Fully offline — **no LLM API key** used: the v3 track makes no model call as
> long as `OPENAI_API_KEY` is empty, and it was empty; the OpenAI real-call path was
> **not** run. The earlier run (2026-07-26: v3.197.1 / SDK 3.7.0 / ClickHouse 25.11.2.24,
> Python 3.9) is mentioned only where it differs, and is marked as not re-run.

---

## 1. The hook

Most Langfuse tutorials stop at "send a trace." But the reason teams adopt an LLM
observability platform is the next question: **is my app actually any good, and did
my last change make it better or worse?**

Langfuse answers that with a tight loop of product features — **prompt management →
datasets → experiments → LLM-as-a-judge → human annotation** — and, because it is
self-hosted on **ClickHouse**, every quality signal it produces is queryable SQL.

This post walks that loop end to end on a self-hosted instance, then drops into the
ClickHouse backend to show where the numbers physically live.

> Everything shown is **OSS (MIT)** — no license key. The only optional extra is an
> LLM key for *real* generation and Langfuse's *managed* judges; without it the whole
> loop runs offline with deterministic code evaluators.

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

The punchline for a data platform audience: **user feedback, code evaluators, the LLM
judge, and human annotations all converge into one ClickHouse table — `scores` —
distinguished by a `source` column.** That single table is what makes cross-cutting
quality analytics (agreement, drift, A/B) a plain `SELECT`.

---

## 3. Setup

The lab runs on the shared self-hosted stack in `_base/` (the same stack the sibling
`langfuse-ee` lab uses). Bring it up and install the SDK:

```bash
# from the repository root
cp _base/.env.example _base/.env     # edit the # CHANGEME secrets for anything non-local

# 1) stack (postgres · clickhouse · redis · minio · web · worker)
_base/bin/up.sh v3
_base/bin/check.sh v3
#    → http://localhost:3000   login admin@example.com / workshop-admin-pw
#    → project "LLM Observability"  (public key pk-lf-workshop-public)

# 2) SDK
python3.12 -m venv .venv-v3 && source .venv-v3/bin/activate
pip install -r _base/v3/requirements.txt      # pins langfuse==3.15.0
cd labs/v3/langfuse-eval
```

The run started from a purged stack (`_base/bin/down.sh v3 --purge` removed the network
and all five data volumes), so the only data in the project is what this lab creates.
`check.sh` after `up.sh`:

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

A tiny `_common.py` centralizes the boring parts — `.env` loading, the client, a REST
helper for endpoints without an SDK method, and the shared Q&A knowledge base:

```python
def client():
    from langfuse import Langfuse, get_client
    Langfuse(host=..., public_key=..., secret_key=...)
    lf = get_client()
    if not lf.auth_check():
        raise SystemExit("Auth failed — is the stack up and are LANGFUSE_* keys set?")
    return lf
```

---

## 4. Step 01 — seed traces to evaluate

You can't evaluate an empty project. We reuse a trace generator (a customer-support
RAG assistant) to seed ~20 nested traces with token usage, tags, and user-feedback
scores.

```bash
python 01-seed-traces.py 20
```

```text
✓ Connected. Generating 20 traces (offline / simulated)…
  …10/20 traces
  …20/20 traces
✓ Done. Open http://localhost:3000 → Tracing → Traces.
  Then run the ClickHouse labs:  03-clickhouse-explore.sql, 04-clickhouse-analytics.sql
→ Seeding 20 traces with the shared trace generator:
  _base/v3/seed_traces.py
```

(`01-seed-traces.py` is a thin wrapper around the shared generator in `_base/v3/`; the
`→ Seeding` lines come last in the captured log.)

---

## 5. Step 02 — Prompt management

Store the system prompt **in Langfuse, not in code**. Create **v1** (terse) and **v2**
(guard-railed). Creating v2 with the `production` label instantly *deploys* it (the
label moves), while v1 stays reachable by version number. Fetch by label, fill
variables with `.compile()`, and **link** the prompt to a generation with `prompt=` so
the UI can attribute performance to that version.

```python
lf.create_prompt(name="support-system", type="text",
    prompt="You are a {{tone}} customer-support assistant. "
           "Answer the user's question in one short sentence.",
    labels=["production"], config={"model": "gpt-4o-mini", "temperature": 0.2})

# v2 — creating with `production` MOVES the label here (a deploy); `latest` too.
lf.create_prompt(name="support-system", type="text",
    prompt="You are a {{tone}} customer-support assistant. Answer in one short "
           "sentence using only verified product facts. If you are unsure, say you "
           "will escalate to a human — never invent policy.",
    labels=["production", "latest"], config={"model": "gpt-4o-mini", "temperature": 0.2})

prod = lf.get_prompt("support-system")                 # → v2 (production)
with lf.start_as_current_observation(as_type="generation", name="demo",
                                     model="gpt-4o-mini", prompt=prod) as gen:  # ← link
    gen.update(output="…", usage_details={"input_tokens": 42, "output_tokens": 18})
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

A dataset is a reusable set of test cases: `input` + `expected_output`. Passing a
stable `id=` makes re-runs **idempotent** (upsert, not duplicate).

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
auto-traces each run, and scores it. We run it **twice** — prompt v1 vs v2 — with three
**code evaluators** (no LLM key): `keyword-recall`, `length-ok`, `answered`.

```python
from langfuse import Evaluation

def keyword_recall(*, input, output, expected_output, **kwargs):
    key = {w for w in re.findall(r"[a-z]+", expected_output.lower()) if len(w) > 4}
    hits = sum(1 for w in key if w in output.lower())
    return Evaluation(name="keyword-recall", value=round(hits / len(key), 3))

def answered(*, output, **kwargs):
    deflecting = "check our documentation" in output.lower() or "contact support" in output.lower()
    return Evaluation(name="answered", value=0.0 if deflecting else 1.0)

def make_task(prompt_obj, variant):
    system_prompt = prompt_obj.compile(tone="friendly")
    def task(*, item, **kwargs):
        lf.update_current_trace(tags=[f"variant:{variant}", "eval-experiment"])   # ← for CH A/B
        with lf.start_as_current_observation(as_type="generation", name="answer-generation",
                                             model="gpt-4o-mini", prompt=prompt_obj) as gen:
            ans = generate_answer(system_prompt=system_prompt, question=item.input["question"],
                                  expected=item.expected_output, variant=variant)
            gen.update(output=ans, usage_details={...})
        return ans
    return task

res_v1 = dataset.run_experiment(name="prompt-v1", task=make_task(prompt_v1, "v1"),
                                evaluators=[keyword_recall, length_ok, answered])
res_v2 = dataset.run_experiment(name="prompt-v2", task=make_task(prompt_v2, "v2"),
                                evaluators=[keyword_recall, length_ok, answered])
```

```text
Running experiments over 'support-golden-qa' (offline / simulated)…

──────── prompt-v1 ────────
Individual Results: Hidden (10 items)
💡 Set include_item_results=True to view them

──────────────────────────────────────────────────
🧪 Experiment: prompt-v1
📋 Run name: prompt-v1 - 2026-10-08T06:01:52.176278Z - Terse v1 system prompt
10 items
Evaluations:
  • keyword-recall
  • answered
  • length-ok

Average Scores:
  • keyword-recall: 0.000
  • answered: 0.000
  • length-ok: 1.000

🔗 Dataset Run:
   http://localhost:3000/project/llm-observability/datasets/cmuz4pla70009mm07ipgytetm/runs/998adb92-306c-4c7d-b48b-ccc4d4805d2d

──────── prompt-v2 ────────
Individual Results: Hidden (10 items)
💡 Set include_item_results=True to view them

──────────────────────────────────────────────────
🧪 Experiment: prompt-v2
📋 Run name: prompt-v2 - 2026-10-08T06:01:52.303998Z - Guard-railed v2 system prompt
10 items
Evaluations:
  • keyword-recall
  • answered
  • length-ok

Average Scores:
  • keyword-recall: 1.000
  • answered: 1.000
  • length-ok: 1.000

🔗 Dataset Run:
   http://localhost:3000/project/llm-observability/datasets/cmuz4pla70009mm07ipgytetm/runs/4f45afa9-d1d5-4ec0-8347-5323b32b41b6

✓ Two runs created. UI → Datasets → support-golden-qa → Runs: compare prompt-v1 vs prompt-v2 side by side.
  Tip: swap MODEL in make_task to also compare models on the same dataset.
```

> **SDK 3.15.0 quirk.** `ExperimentResult.format()` builds its summary with escaped
> `\\n` (`langfuse/experiment.py:528` in the installed SDK), so it prints a literal `\n`
> instead of a line break and each summary is one long line in the captured log. The
> blocks above and in step 05 are the decoded text — every `\n` replaced by a newline,
> nothing else changed.

The guard-railed v2 answers on-topic and grounded; the terse v1 deflects. In the UI,
**Datasets → Runs** shows the two runs side by side.

---

## 8. Step 05 — LLM-as-a-judge (hybrid)

Use a model to grade the output. The evaluator is a judge: offline it applies a
deterministic rubric; with `OPENAI_API_KEY` it makes a real grading call.

```python
def llm_judge(*, input, output, expected_output, **kwargs):
    if os.environ.get("OPENAI_API_KEY"):
        # real grading call → "Score 0.0–1.0. Reply with ONLY the number."
        ...
        return Evaluation(name="llm-judge-correctness", value=score)
    # offline: token overlap with the reference, zeroed on deflections
    return Evaluation(name="llm-judge-correctness", value=overlap)
```

```text
Judging both prompt versions with the offline rubric judge…

──────── judge-prompt-v1 ────────
…

──────────────────────────────────────────────────
🧪 Experiment: judge-prompt-v1
📋 Run name: judge-prompt-v1 - 2026-10-08T06:01:54.553382Z - LLM judge on v1
10 items
Evaluations:
  • llm-judge-correctness

Average Scores:
  • llm-judge-correctness: 0.000

🔗 Dataset Run:
   http://localhost:3000/project/llm-observability/datasets/cmuz4pla70009mm07ipgytetm/runs/6bfe7633-1a93-40e3-a2a7-7770442e8fb4

──────── judge-prompt-v2 ────────
…

──────────────────────────────────────────────────
🧪 Experiment: judge-prompt-v2
📋 Run name: judge-prompt-v2 - 2026-10-08T06:01:55.557845Z - LLM judge on v2
10 items
Evaluations:
  • llm-judge-correctness

Average Scores:
  • llm-judge-correctness: 1.000

🔗 Dataset Run:
   http://localhost:3000/project/llm-observability/datasets/cmuz4pla70009mm07ipgytetm/runs/dbba8051-3405-44f4-b6a9-1cab4ba222c5

✓ LLM-judge scores written (name: llm-judge-correctness, source=API via SDK).
  Managed evaluators (Hallucination/Toxicity/…, source=EVAL): 05-llm-as-a-judge.md
```

(Decoded as in step 04; the `Individual Results: Hidden …` lines are elided with `…`.)

**Managed judges.** Langfuse also ships maintained evaluator templates (Hallucination,
Toxicity, Context-Relevance, Helpfulness, Ragas) that run *continuously* on production
traces or dataset runs and write `source = 'EVAL'`. They require a structured-output
model in the UI's *LLM Connections*. (Covered in `05-llm-as-a-judge.md`; **not run on
2026-10-08** — this run was offline and used no LLM connection.)

---

## 9. Step 06 — Annotation queues (human-in-the-loop)

Define **score configs** (the review dimensions), a **queue** bound to them, and enqueue
traces. All via the Public REST API (Basic auth); the Python SDK has no helper for these.

```python
# score configs
quality_id = api("POST", "/api/public/score-configs",
    {"name": "answer-quality", "dataType": "CATEGORICAL",
     "categories": [{"label": "good", "value": 1}, {"label": "ok", "value": 0.5},
                    {"label": "bad", "value": 0}]})["id"]
correct_id = api("POST", "/api/public/score-configs",
    {"name": "factually-correct", "dataType": "BOOLEAN"})["id"]

# queue
queue_id = api("POST", "/api/public/annotation-queues",
    {"name": "human-review", "scoreConfigIds": [quality_id, correct_id]})["id"]

# enqueue traces that already have user feedback (so signals co-occur — see §11)
scored = api("GET", "/api/public/v2/scores?name=user-thumbs&limit=25")["data"]
trace_ids = list(dict.fromkeys(s["traceId"] for s in scored))[:8]
for tid in trace_ids:
    api("POST", f"/api/public/annotation-queues/{queue_id}/items",
        {"objectId": tid, "objectType": "TRACE"})
```

```text
✓ score configs: answer-quality=482801cc… factually-correct=cd2b66db…
✓ queue 'human-review' = cmuz4pvhc000omm07am8v3z9c
✓ enqueued 8 traces for human review
✓ wrote demo review scores on 8 traces
```

Real reviewers score in the keyboard-driven **UI → Annotations** queue; those scores
arrive with `source = 'ANNOTATION'`. (A manual UI step — **not performed on 2026-10-08**;
every score in step 07 below is `source = API`, including the script's demo review scores.)

---

## 10. Step 07 — Every signal, unified in ClickHouse (the payoff)

Now the SA moment: plain SQL on the `scores` table. Langfuse tables are
`ReplacingMergeTree`, so read with `FINAL` + `WHERE is_deleted = 0`.

```bash
docker exec -i langfuse-hols-v3-clickhouse-1 clickhouse-client \
  -u clickhouse --password clickhouse --multiquery < 07-scores-in-clickhouse.sql
```

The `scores` schema (abridged `DESCRIBE`):

```
trace_id  Nullable(String)   name       String    value     Float64
source    String             data_type  String    string_value Nullable(String)
dataset_run_id Nullable(String)   queue_id Nullable(String)   is_deleted UInt8   timestamp DateTime64(3)
```

### 10.1 The unified score model — every signal, by source & name

```sql
SELECT source, name, any(data_type) AS data_type, count() AS n, round(avg(value),3) AS avg_value
FROM scores FINAL WHERE is_deleted = 0
GROUP BY source, name ORDER BY source, name;
```

```text
source  name                      data_type  n    avg_value
API     answered                  NUMERIC    20   0.5
API     hallucination-check       NUMERIC    19   0.817
API     human-answer-quality      NUMERIC     8   0.875
API     human-factually-correct   BOOLEAN     8   0.75
API     keyword-recall            NUMERIC    20   0.5
API     length-ok                 NUMERIC    20   1
API     llm-judge-correctness     NUMERIC    20   0.5
API     user-thumbs               BOOLEAN    20   0.8
```

> Note: offline, everything is `source = API` (written via the SDK). Langfuse's
> **managed** evaluators write `EVAL`; **UI** annotations write `ANNOTATION`. One table,
> three provenances. This run started from a purged stack, so only this lab's own
> signals appear (the seed traces' `user-thumbs` / `hallucination-check` plus the
> lab's evaluator, judge and demo-review series). On the 2026-07-26 shared stack a
> `pii-demo` series from the sibling lab also showed up there; that was not re-run.

### 10.2 Volume by data type

```sql
SELECT data_type, count() AS n,
       countIf(value IS NOT NULL) AS numeric_vals,
       countIf(string_value != '') AS string_vals
FROM scores FINAL WHERE is_deleted = 0
GROUP BY data_type ORDER BY n DESC;
```

```text
data_type  n    numeric_vals  string_vals
NUMERIC    107  107           0
BOOLEAN     28   28           28
```

### 10.3 Numeric distribution per metric (p50/p90)

```sql
SELECT name, count() n, round(avg(value),3) mean,
       round(quantile(0.5)(value),3) p50, round(quantile(0.9)(value),3) p90,
       round(min(value),3) min, round(max(value),3) max
FROM scores FINAL WHERE is_deleted = 0 AND data_type = 'NUMERIC'
GROUP BY name ORDER BY name;
```

```text
name                   n    mean   p50   p90    min  max
answered               20   0.5    0.5   1      0    1
hallucination-check    19   0.817  0.8   0.972  0.6  1
human-answer-quality    8   0.875  1     1      0.5  1
keyword-recall         20   0.5    0.5   1      0    1
length-ok              20   1      1     1      1    1
llm-judge-correctness  20   0.5    0.5   1      0    1
```

### 10.4 Experiment A/B — reconstructed in ClickHouse

Evaluator scores don't carry the dataset-run id in ClickHouse, but lab 04 tagged each
experiment trace with its variant — so a `scores → traces` join reconstructs the A/B:

```sql
SELECT multiIf(has(t.tags,'variant:v1'),'prompt-v1',
               has(t.tags,'variant:v2'),'prompt-v2','other') AS variant,
       s.name AS metric, count() AS n, round(avg(s.value),3) AS avg_value
FROM scores AS s FINAL
INNER JOIN traces AS t FINAL ON s.trace_id = t.id
WHERE s.is_deleted = 0 AND t.is_deleted = 0 AND has(t.tags,'eval-experiment')
  AND s.name IN ('keyword-recall','answered','llm-judge-correctness')
GROUP BY variant, metric ORDER BY metric, variant;
```

```text
variant     metric                 n    avg_value
prompt-v1   answered               10   0
prompt-v2   answered               10   1
prompt-v1   keyword-recall         10   0
prompt-v2   keyword-recall         10   1
prompt-v1   llm-judge-correctness  10   0
prompt-v2   llm-judge-correctness  10   1
```

**v2 beats v1 across all three metrics — code evaluators and the LLM judge agree — and
it's a single GROUP BY.**

### 10.5 Per-trace agreement of co-occurring signals

Pivot to one row per trace: user sentiment vs the automated hallucination check vs the
human review, all on the same seed traces.

```sql
SELECT trace_id,
       anyIfOrNull(value, name='user-thumbs')          AS user_thumbs,
       anyIfOrNull(value, name='hallucination-check')  AS halluc_check,
       anyIfOrNull(value, name='human-answer-quality') AS human_quality
FROM scores FINAL WHERE is_deleted = 0
  AND name IN ('user-thumbs','hallucination-check','human-answer-quality')
GROUP BY trace_id
HAVING countIf(name='user-thumbs') > 0 AND countIf(name='human-answer-quality') > 0
ORDER BY trace_id LIMIT 20;
```

```text
trace_id                          user_thumbs  halluc_check  human_quality
07f194f9c1156d6d0a4e5b70a6d964a3       1           0.93           1
269cd696236c7b8714a0bccb8a476a87       1           0.83           1
3e2b6091a092f52ad4a057a7b0cc1b3b       0           \N             0.5     ← error trace: no check
a2086977a9f2533683f4a9a948a639d0       0           0.88           1
ab3b4d37560c95ee638c254c076e2bba       1           0.98           1
b841d0a01fe771d6d9178793a9d3c2e6       1           0.77           1
eadf50853fcb75468eb225790cdb1ca4       1           0.71           0.5
f86c2ca2e08596db1d8709660710d430       1           0.6            1
```

The `\N` row is an error trace: the seeder writes a thumbs-down and no `hallucination-check`
for it, and `anyIfOrNull` shows the missing score as `NULL`. Plain `anyIf` returned the
`Float64` default `0` there, which earlier versions of this page read as "the hallucination
check scored 0" ([#46](https://github.com/litkhai/langfuse-hols/issues/46)). So two signals
flag `3e2b6091…` (the user's thumbs-down and the human's `0.5`), not three. That cross-signal
view is the analysis the UI doesn't give you and ClickHouse does.

The seeder is deterministic, so these trace ids and values are the same on every fresh run.

### 10.6 Daily trend

```sql
SELECT toDate(timestamp) AS day, count() AS n_scores, round(avg(value),3) AS avg_llm_judge
FROM scores FINAL WHERE is_deleted = 0 AND name = 'llm-judge-correctness'
GROUP BY day ORDER BY day;
```

```text
day          n_scores  avg_llm_judge
2026-10-08   20        0.5
```

---

## 11. Field notes — what the SDK actually does (blog-worthy gotchas)

These are the non-obvious behaviors we hit and had to design around. They make good
"here's what the docs don't tell you" material.

1. **Experiment scores are `source = API`, not `EVAL`.** In SDK 3.15.0 (this run; the
   earlier run on SDK 3.7.0 saw the same), scores written by `run_experiment` evaluators
   (including an in-code LLM judge) land as `source=API` — every row of §10.1 is `API`.
   Only Langfuse's *managed* evaluators write `EVAL`; only UI annotations write
   `ANNOTATION` (neither was run on 2026-10-08). Query by `source` accordingly.

2. **`dataset_run_id` is not populated on scores in ClickHouse.** The column exists (it
   is in the `DESCRIBE` output above) but was found empty for evaluator scores on the
   2026-07-26 run — the run linkage lives in Postgres. That emptiness was **not
   re-checked on 2026-10-08** (`07-scores-in-clickhouse.sql` does not query the column).
   To reconstruct an A/B in ClickHouse, **tag the experiment trace**
   (`lf.update_current_trace(tags=…)`) and join `scores → traces` — §10.4 does exactly
   that on this run's data.

3. **`config_id` binding is strictly typed.** A `create_score(config_id=…)` whose
   `data_type` doesn't match the config's is silently dropped at ingestion (a NUMERIC
   score against a CATEGORICAL config just vanished). Either match the type exactly or
   leave the score unbound. *(Seen while developing the lab on the earlier run; no step
   in the 2026-10-08 run exercises it — not re-run.)*

4. **Scores ingest asynchronously.** They flow SDK → worker → ClickHouse; allow a few
   seconds before querying `scores`. Poll, don't assume. (The earlier run saw ~seconds
   to ~2 min under load; on 2026-10-08 a 10 s pause before the SQL step was enough for
   every series in §10.1 to be complete.)

5. **Trace names are not unique across labs on a shared stack.** Selecting "recent
   traces named `support-request`" picked up a *neighboring* lab's PII traces (same
   name), so a cross-signal join found nothing in common. Fix: **select traces by a score
   they carry** (`GET /api/public/v2/scores?name=user-thumbs`), not by name. *(Hit on the
   2026-07-26 shared stack. The 2026-10-08 run started from a purged stack with no
   neighbouring data, so it did not reproduce the clash — not re-run.)*

6. **Two databases, two jobs.** Prompts, datasets, and annotation queues live in
   **Postgres**; traces, observations, and **scores** live in **ClickHouse**. If a stack
   reset wipes the Postgres volume, your datasets/prompts disappear while ClickHouse
   traces may survive — re-run the create scripts to repopulate.

---

## 12. Verification table

One row per step; `rc` = exit code, `s` = seconds. The run paused 10 s after step 06 so the
worker could finish ingesting before step 07.

| Step | rc | s | Result |
|---|--:|--:|---|
| reset (`down.sh v3 --purge`) | 0 | 7 | ✅ stack, network and 5 volumes removed |
| up (`up.sh v3`) | 0 | 22 | ✅ `Langfuse is up after ~15s` |
| check (`check.sh v3`) | 0 | 1 | ✅ 11 PASS, 1 SKIP (masking sidecar, lab 08 only); `Langfuse 3.225.11` |
| `01` seed | 0 | 19 | ✅ 20 traces generated |
| `02` prompts | 0 | 1 | ✅ v1 + v2 + chat; `production` label moved to v2; compile + `prompt=` link OK |
| `03` dataset | 0 | 3 | ✅ 10 items upserted (`golden-00…09`), idempotent |
| `04` experiments | 0 | 3 | ✅ prompt-v1 `answered 0.000 / keyword-recall 0.000` → prompt-v2 `1.000 / 1.000` |
| `05` LLM-judge | 0 | 4 | ✅ `judge-prompt-v1 = 0.000`, `judge-prompt-v2 = 1.000` (offline rubric) |
| `06` annotation | 0 | 4 | ✅ 2 score configs + `human-review` queue + 8 traces enqueued + demo scores |
| `07` ClickHouse | 0 | 0 | ✅ unified model (8 series, all `API`) + tag-join A/B (v2 ≫ v1 on 3 metrics) + per-trace agreement (8 traces) |

Environment: Langfuse v3.225.11 · SDK `langfuse` 3.15.0 · ClickHouse 26.8.19.9 · Python 3.12.14 · offline.

---

## 13. Suggested blog outline

1. **Why evaluation is the real reason to run an LLM observability platform** (§1)
2. **The quality loop in one diagram** (§2)
3. **Prompts as versioned, deployable artifacts** (§5)
4. **Datasets + experiments: catching a regression before prod** (§6–7, lead with the A/B log)
5. **Judging at scale: code evaluators, LLM-as-a-judge, and managed judges** (§8)
6. **Humans in the loop** (§9)
7. **The ClickHouse payoff: one `scores` table, every signal** (§10 — this is the
   differentiator for a ClickHouse audience; lead with §10.4 and §10.5)
8. **Field notes / gotchas** (§11)
9. **Try it yourself** — link the lab, note it's OSS and runs offline

**Recommended hero visuals:** the §10.4 A/B result (prompt-v1 vs v2, all zeros → all
ones) and the §10.5 agreement table (the `3e2b…` row, where the user and the reviewer both flag a weak answer).

---

*Source lab: [`labs/v3/langfuse-eval/`](./README.md) · Governance sibling:
[`labs/v3/langfuse-ee/`](../langfuse-ee/README.md) · Author: Ken Lee (ClickHouse SA).*
