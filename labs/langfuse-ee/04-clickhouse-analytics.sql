-- ════════════════════════════════════════════════════════════════════════════
-- 04-clickhouse-analytics.sql
-- SA-style LLM-observability analytics, run DIRECTLY on Langfuse's ClickHouse.
--
-- These are the same kinds of questions the Langfuse UI answers — cost, latency,
-- token usage, quality — but here we express them as plain ClickHouse SQL to show
-- WHY ClickHouse is the right OLAP store for this workload: high-cardinality
-- append-only events, conditional aggregation, quantiles, and Map columns.
--
-- Run:
--   docker compose exec -T clickhouse clickhouse-client \
--     -u clickhouse --password clickhouse --multiquery < 04-clickhouse-analytics.sql
--
-- ── TWO THINGS THAT MAKE THESE QUERIES CORRECT ──────────────────────────────
-- 1) ReplacingMergeTree: Langfuse re-ingests a row every time a trace/observation
--    is updated (e.g. a span gets its output after creation). Until a background
--    merge collapses them, BOTH versions are on disk. We therefore read with
--    `FINAL` (collapse to the newest version) and `WHERE is_deleted = 0` (drop
--    soft-deletes). Without FINAL you double-count and see half-populated rows.
-- 2) Map keys: the SDK sends usage as input_tokens/output_tokens, but Langfuse
--    normalizes them to the keys `input` / `output` / `total`. We use greatest()
--    over both spellings so the queries work regardless of SDK version.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) Spend & token usage by model (the bread-and-butter cost report) ───────
SELECT
    provided_model_name                                                     AS model,
    count()                                                                 AS calls,
    sum(greatest(usage_details['input_tokens'],  usage_details['input']))   AS input_tokens,
    sum(greatest(usage_details['output_tokens'], usage_details['output']))  AS output_tokens,
    round(sum(cost_details['input'] + cost_details['output']), 6)           AS total_cost_usd,
    round(sum(cost_details['input'] + cost_details['output'])
            / nullIf(count(), 0), 6)                                        AS avg_cost_per_call
FROM default.observations FINAL
WHERE type = 'GENERATION' AND is_deleted = 0
GROUP BY model
ORDER BY total_cost_usd DESC;

-- ── 2) Latency distribution per model — p50 / p95 / p99 in one pass ──────────
SELECT
    provided_model_name                                            AS model,
    count()                                                        AS calls,
    round(avg(dateDiff('millisecond', start_time, end_time)))      AS avg_ms,
    quantile(0.50)(dateDiff('millisecond', start_time, end_time))  AS p50_ms,
    quantile(0.95)(dateDiff('millisecond', start_time, end_time))  AS p95_ms,
    quantile(0.99)(dateDiff('millisecond', start_time, end_time))  AS p99_ms
FROM default.observations FINAL
WHERE type = 'GENERATION' AND is_deleted = 0 AND end_time > start_time
GROUP BY model
ORDER BY p95_ms DESC;

-- ── 3) Error rate per model (level = 'ERROR') — countIf conditional aggregation
SELECT
    provided_model_name                                  AS model,
    count()                                              AS calls,
    countIf(level = 'ERROR')                             AS errors,
    round(100.0 * countIf(level = 'ERROR') / count(), 2) AS error_pct
FROM default.observations FINAL
WHERE type = 'GENERATION' AND is_deleted = 0
GROUP BY model
ORDER BY error_pct DESC;

-- ── 4) Cost & quality by customer tier — joins traces (tags/metadata) to cost ─
--    Tags were set as ['env:…','feature:…','tier:…']; pull the tier back out.
WITH trace_tier AS (
    SELECT
        id AS trace_id,
        arrayFirst(t -> t LIKE 'tier:%', tags) AS tier_tag
    FROM default.traces FINAL
    WHERE is_deleted = 0
)
SELECT
    replaceOne(tt.tier_tag, 'tier:', '')                       AS tier,
    count(DISTINCT o.trace_id)                                 AS traces,
    round(sum(o.cost_details['input'] + o.cost_details['output']), 6) AS cost_usd,
    round(sum(o.cost_details['input'] + o.cost_details['output'])
            / nullIf(count(DISTINCT o.trace_id), 0), 6)        AS cost_per_trace
FROM default.observations AS o FINAL
INNER JOIN trace_tier AS tt ON tt.trace_id = o.trace_id
WHERE o.type = 'GENERATION' AND o.is_deleted = 0 AND tt.tier_tag != ''
GROUP BY tier
ORDER BY cost_usd DESC;

-- ── 5) User satisfaction from scores — thumbs-up rate + grounding ────────────
SELECT
    countIf(name = 'user-thumbs')                                          AS thumbs_votes,
    round(100.0 * sumIf(value, name = 'user-thumbs')
            / nullIf(countIf(name = 'user-thumbs'), 0), 1)                 AS thumbs_up_pct,
    round(avgIf(value, name = 'hallucination-check'), 3)                   AS avg_grounding
FROM default.scores FINAL
WHERE is_deleted = 0;

-- ── 6) Per-user spend & engagement leaderboard (cost attribution) ────────────
SELECT
    t.user_id,
    count(DISTINCT t.session_id)                               AS sessions,
    count(DISTINCT t.id)                                       AS requests,
    round(sum(o.cost_details['input'] + o.cost_details['output']), 6) AS cost_usd
FROM default.traces AS t FINAL
INNER JOIN default.observations AS o FINAL
    ON o.trace_id = t.id AND o.type = 'GENERATION' AND o.is_deleted = 0
WHERE t.is_deleted = 0
GROUP BY t.user_id
ORDER BY cost_usd DESC
LIMIT 10;

-- ── 7) Daily trend — traces, unique users, spend (time-series over partitions)
SELECT
    toDate(t.timestamp)                                       AS day,
    count(DISTINCT t.id)                                      AS traces,
    uniqExact(t.user_id)                                      AS users,
    round(sum(o.cost_details['input'] + o.cost_details['output']), 6) AS cost_usd
FROM default.traces AS t FINAL
LEFT JOIN default.observations AS o FINAL
    ON o.trace_id = t.id AND o.type = 'GENERATION' AND o.is_deleted = 0
WHERE t.is_deleted = 0
GROUP BY day
ORDER BY day;

-- ── 8) Session depth — how many turns per conversation (session_id grouping) ─
SELECT
    turns,
    count()             AS sessions
FROM (
    SELECT session_id, count(DISTINCT id) AS turns
    FROM default.traces FINAL
    WHERE is_deleted = 0 AND session_id != ''
    GROUP BY session_id
)
GROUP BY turns
ORDER BY turns;
