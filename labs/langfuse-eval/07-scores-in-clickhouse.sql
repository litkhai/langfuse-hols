-- ─────────────────────────────────────────────────────────────────────────────
-- 07-scores-in-clickhouse.sql — the quality loop's payoff, in ClickHouse.
--
-- Every quality signal in this lab — user feedback (01), code evaluators (04),
-- the LLM judge (05), human annotations (06) — converges into ONE table:
-- `scores`, distinguished by the `source` column (API / EVAL / ANNOTATION).
-- That lets you run cross-cutting quality analytics the UI does not offer.
--
-- Langfuse tables are ReplacingMergeTree → read with FINAL + WHERE is_deleted = 0
-- to avoid double-counting un-merged row versions (learned in the sibling lab).
--
-- Run against the SAME stack as the langfuse-ee lab:
--   docker compose -f ../langfuse-ee/docker-compose.yml exec -T clickhouse \
--     clickhouse-client -u clickhouse --password clickhouse --multiquery \
--     < 07-scores-in-clickhouse.sql
-- ─────────────────────────────────────────────────────────────────────────────

-- 0) Schema is the source of truth for your installed version.
DESCRIBE TABLE scores;

SELECT '── 1) The unified score model: every signal, by source & name ──' AS section;
SELECT
    source,                                  -- API | EVAL | ANNOTATION
    name,
    any(data_type)          AS data_type,
    count()                 AS n,
    round(avg(value), 3)    AS avg_value
FROM scores FINAL
WHERE is_deleted = 0
GROUP BY source, name
ORDER BY source, name;

SELECT '── 2) Score volume by data type ──' AS section;
SELECT
    data_type,
    count()                             AS n,
    countIf(value IS NOT NULL)          AS numeric_vals,
    countIf(string_value != '')         AS string_vals
FROM scores FINAL
WHERE is_deleted = 0
GROUP BY data_type
ORDER BY n DESC;

SELECT '── 3) Numeric score distribution per metric (p50/p90) ──' AS section;
SELECT
    name,
    count()                                   AS n,
    round(avg(value), 3)                      AS mean,
    round(quantile(0.50)(value), 3)           AS p50,
    round(quantile(0.90)(value), 3)           AS p90,
    round(min(value), 3)                      AS min,
    round(max(value), 3)                      AS max
FROM scores FINAL
WHERE is_deleted = 0 AND data_type = 'NUMERIC'
GROUP BY name
ORDER BY name;

SELECT '── 4) Experiment A/B: avg score per metric, split by prompt variant ──' AS section;
-- Evaluator scores don't carry the dataset-run id in ClickHouse, but lab 04 tags
-- each experiment trace with its variant — so a scores → traces JOIN reconstructs
-- the prompt-v1 vs prompt-v2 comparison right here in ClickHouse.
SELECT
    multiIf(has(t.tags, 'variant:v1'), 'prompt-v1',
            has(t.tags, 'variant:v2'), 'prompt-v2', 'other') AS variant,
    s.name                    AS metric,
    count()                   AS n,
    round(avg(s.value), 3)    AS avg_value
FROM scores AS s FINAL
INNER JOIN traces AS t FINAL ON s.trace_id = t.id
WHERE s.is_deleted = 0 AND t.is_deleted = 0
  AND has(t.tags, 'eval-experiment')
  AND s.name IN ('keyword-recall', 'answered', 'llm-judge-correctness')
GROUP BY variant, metric
ORDER BY metric, variant;

SELECT '── 5) Per-trace agreement of signals that co-occur (seed traces) ──' AS section;
-- user feedback (01) vs automated hallucination-check (01) vs demo human review (06),
-- all attached to the same seed traces. Pivot to one row per trace.
SELECT
    trace_id,
    anyIf(value, name = 'user-thumbs')            AS user_thumbs,
    anyIf(value, name = 'hallucination-check')    AS halluc_check,
    anyIf(value, name = 'human-answer-quality')   AS human_quality
FROM scores FINAL
WHERE is_deleted = 0
  AND name IN ('user-thumbs', 'hallucination-check', 'human-answer-quality')
GROUP BY trace_id
HAVING countIf(name = 'user-thumbs') > 0 AND countIf(name = 'human-answer-quality') > 0
ORDER BY trace_id
LIMIT 20;

SELECT '── 6) Daily trend of judged correctness ──' AS section;
SELECT
    toDate(timestamp)               AS day,
    count()                         AS n_scores,
    round(avg(value), 3)            AS avg_llm_judge
FROM scores FINAL
WHERE is_deleted = 0 AND name = 'llm-judge-correctness'
GROUP BY day
ORDER BY day;

-- NOTE: per-trace HUMAN vs LLM-JUDGE agreement needs both on the SAME traces.
-- Offline, the judge scores dataset-experiment traces while humans review seed
-- traces. To align them, run a MANAGED LLM-as-a-judge evaluator on production
-- traces (see 05-llm-as-a-judge.md) — those scores (source='EVAL') then sit on
-- the same traces your annotators review (source='ANNOTATION').
