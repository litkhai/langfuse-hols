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
-- Robustness: cost is read from cost_details (input+output) and tokens via a
-- greatest() over the common key spellings, so these work regardless of whether
-- the SDK sent `input_tokens`/`output_tokens` or `input`/`output`.
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
FROM default.observations
WHERE type = 'GENERATION'
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
FROM default.observations
WHERE type = 'GENERATION' AND end_time > start_time
GROUP BY model
ORDER BY p95_ms DESC;

-- ── 3) Error rate per model (level = 'ERROR') — countIf conditional aggregation
SELECT
    provided_model_name                                  AS model,
    count()                                              AS calls,
    countIf(level = 'ERROR')                             AS errors,
    round(100.0 * countIf(level = 'ERROR') / count(), 2) AS error_pct
FROM default.observations
WHERE type = 'GENERATION'
GROUP BY model
ORDER BY error_pct DESC;

-- ── 4) Cost & quality by customer tier — joins traces (tags/metadata) to cost ─
--    Tags were set as ['env:…','feature:…','tier:…']; pull the tier back out.
WITH trace_tier AS (
    SELECT
        id AS trace_id,
        arrayFirst(t -> t LIKE 'tier:%', tags) AS tier_tag
    FROM default.traces
)
SELECT
    replaceOne(tt.tier_tag, 'tier:', '')                       AS tier,
    count(DISTINCT o.trace_id)                                 AS traces,
    round(sum(o.cost_details['input'] + o.cost_details['output']), 6) AS cost_usd,
    round(sum(o.cost_details['input'] + o.cost_details['output'])
            / nullIf(count(DISTINCT o.trace_id), 0), 6)        AS cost_per_trace
FROM default.observations AS o
INNER JOIN trace_tier AS tt ON tt.trace_id = o.trace_id
WHERE o.type = 'GENERATION' AND tt.tier_tag != ''
GROUP BY tier
ORDER BY cost_usd DESC;

-- ── 5) User satisfaction from scores — thumbs-up rate + grounding ────────────
SELECT
    countIf(name = 'user-thumbs')                                          AS thumbs_votes,
    round(100.0 * sumIf(value, name = 'user-thumbs')
            / nullIf(countIf(name = 'user-thumbs'), 0), 1)                 AS thumbs_up_pct,
    round(avgIf(value, name = 'hallucination-check'), 3)                   AS avg_grounding
FROM default.scores;

-- ── 6) Per-user spend & engagement leaderboard (cost attribution) ────────────
SELECT
    t.user_id,
    count(DISTINCT t.session_id)                               AS sessions,
    count(DISTINCT t.id)                                       AS requests,
    round(sum(o.cost_details['input'] + o.cost_details['output']), 6) AS cost_usd
FROM default.traces AS t
INNER JOIN default.observations AS o
    ON o.trace_id = t.id AND o.type = 'GENERATION'
GROUP BY t.user_id
ORDER BY cost_usd DESC
LIMIT 10;

-- ── 7) Daily trend — traces, unique users, spend (time-series over partitions)
SELECT
    toDate(t.timestamp)                                       AS day,
    count(DISTINCT t.id)                                      AS traces,
    uniqExact(t.user_id)                                      AS users,
    round(sum(o.cost_details['input'] + o.cost_details['output']), 6) AS cost_usd
FROM default.traces AS t
LEFT JOIN default.observations AS o
    ON o.trace_id = t.id AND o.type = 'GENERATION'
GROUP BY day
ORDER BY day;

-- ── 8) Session depth — how many turns per conversation (session_id grouping) ─
SELECT
    turns,
    count()             AS sessions
FROM (
    SELECT session_id, count(DISTINCT id) AS turns
    FROM default.traces
    WHERE session_id != ''
    GROUP BY session_id
)
GROUP BY turns
ORDER BY turns;
