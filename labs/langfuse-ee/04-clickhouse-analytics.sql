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
--   docker exec -i langfuse-hols-clickhouse-1 clickhouse-client \
--     -u clickhouse --password clickhouse --multiquery < 04-clickhouse-analytics.sql
--
-- ── THREE THINGS THAT MAKE THESE QUERIES CORRECT ────────────────────────────
-- 0) THE v4 LESSON — NO JOINS: Langfuse v4 keeps one wide row per observation in
--    `events_core` (and the full-payload twin `events_full`), and repeats the trace
--    attributes (trace_name, user_id, session_id, tags, metadata, environment) on
--    EVERY row. The v3 questions "join traces to observations to get the user / the
--    tier" disappear: filter or group by the column on the observation row itself.
--    The trace is just the root row (`is_app_root`). Scores stay in their own table
--    and join on scores.trace_id = events_core.trace_id.
-- 1) ReplacingMergeTree: a row sent again with the same sort key is stored twice until
--    a background merge collapses it. We therefore read with `FINAL` (collapse to the
--    newest version) and `WHERE is_deleted = 0` (drop soft-deletes). Without FINAL
--    you can double-count.
-- 2) Cost and tokens: Langfuse prices a generation only when the usage keys match the
--    model's price keys — send `input` / `output` (it derives `total`). Sum the
--    `total_cost` column; `usage_details` and `cost_details` are Maps keyed by
--    `input` / `output` / `total` (plus cache keys on some models).
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) Spend & token usage by model (the bread-and-butter cost report) ───────
SELECT
    provided_model_name                                                     AS model,
    count()                                                                 AS calls,
    sum(usage_details['input'])                                             AS tokens_in,
    sum(usage_details['output'])                                            AS tokens_out,
    round(sum(total_cost), 6)                                               AS total_cost_usd,
    round(sum(total_cost) / nullIf(count(), 0), 6)                          AS avg_cost_per_call
FROM default.events_core FINAL
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
FROM default.events_core FINAL
WHERE type = 'GENERATION' AND is_deleted = 0 AND end_time > start_time
GROUP BY model
ORDER BY p95_ms DESC;

-- ── 3) Error rate per model (level = 'ERROR') — countIf conditional aggregation
SELECT
    provided_model_name                                  AS model,
    count()                                              AS calls,
    countIf(level = 'ERROR')                             AS errors,
    round(100.0 * countIf(level = 'ERROR') / count(), 2) AS error_pct
FROM default.events_core FINAL
WHERE type = 'GENERATION' AND is_deleted = 0
GROUP BY model
ORDER BY error_pct DESC;

-- ── 4) Cost by customer tier — NO join: the tier rides on every observation row ─
--    The generator set it as metadata (`tier`), which v4 stores as two parallel
--    arrays: metadata_names / metadata_values. indexOf() finds the position; a missing
--    key gives index 0 and therefore ''. (The same value is also in `tags`, as
--    'tier:<x>' — arrayFirst(t -> t LIKE 'tier:%', tags) pulls it out of there.)
--    In v3 this needed traces JOIN observations; here the GENERATION rows know their tier.
SELECT
    metadata_values[indexOf(metadata_names, 'tier')]                  AS tier,
    count(DISTINCT trace_id)                                          AS traces,
    round(sum(total_cost), 6)                                         AS cost_usd,
    round(sum(total_cost) / nullIf(count(DISTINCT trace_id), 0), 6)   AS cost_per_trace
FROM default.events_core FINAL
WHERE type = 'GENERATION' AND is_deleted = 0 AND tier != ''
GROUP BY tier
ORDER BY cost_usd DESC;

-- ── 4b) …and quality by tier — the one join v4 still needs: scores → events ──
--    A score row points at its trace with scores.trace_id; take the tier from the
--    trace's ROOT row (is_app_root) so each trace counts once.
SELECT
    t.tier                              AS tier,
    count()                             AS votes,
    round(100.0 * avg(s.value), 1)      AS thumbs_up_pct
FROM (
    SELECT trace_id, metadata_values[indexOf(metadata_names, 'tier')] AS tier
    FROM default.events_core FINAL
    WHERE is_deleted = 0 AND is_app_root AND tier != ''
) AS t
INNER JOIN (
    SELECT trace_id, value
    FROM default.scores FINAL
    WHERE is_deleted = 0 AND name = 'user-thumbs'
) AS s ON s.trace_id = t.trace_id
GROUP BY tier
ORDER BY tier;

-- ── 5) User satisfaction from scores — thumbs-up rate + grounding ────────────
SELECT
    countIf(name = 'user-thumbs')                                          AS thumbs_votes,
    round(100.0 * sumIf(value, name = 'user-thumbs')
            / nullIf(countIf(name = 'user-thumbs'), 0), 1)                 AS thumbs_up_pct,
    round(avgIf(value, name = 'hallucination-check'), 3)                   AS avg_grounding
FROM default.scores FINAL
WHERE is_deleted = 0;

-- ── 6) Per-user spend & engagement leaderboard (cost attribution) ────────────
--    One pass over events_core, no join: user_id is on every row. A request is a
--    root row (is_app_root); cost is the sum over the GENERATION rows.
SELECT
    user_id,
    uniqExact(session_id)                                      AS sessions,
    countIf(is_app_root)                                       AS requests,
    round(sumIf(total_cost, type = 'GENERATION'), 6)           AS cost_usd
FROM default.events_core FINAL
WHERE is_deleted = 0 AND user_id != ''
GROUP BY user_id
ORDER BY cost_usd DESC
LIMIT 10;

-- ── 7) Daily trend — traces, unique users, spend (time-series over partitions)
SELECT
    toDate(start_time)                                         AS day,
    countIf(is_app_root)                                       AS traces,
    uniqExactIf(user_id, user_id != '')                        AS users,
    round(sumIf(total_cost, type = 'GENERATION'), 6)           AS cost_usd
FROM default.events_core FINAL
WHERE is_deleted = 0
GROUP BY day
ORDER BY day;

-- ── 8) Session depth — how many turns per conversation (session_id grouping) ─
SELECT
    turns,
    count()             AS sessions
FROM (
    SELECT session_id, countIf(is_app_root) AS turns
    FROM default.events_core FINAL
    WHERE is_deleted = 0 AND session_id != ''
    GROUP BY session_id
)
GROUP BY turns
ORDER BY turns;
