-- ════════════════════════════════════════════════════════════════════════════
-- 03-clickhouse-explore.sql
-- Peek inside Langfuse's ClickHouse backend.
--
-- Langfuse v4 stores its OLTP state (users, orgs, projects, prompts, audit log)
-- in Postgres, but every OBSERVATION and SCORE lives in ClickHouse. There is no
-- separate trace row any more: a trace is its root observation, and the trace
-- attributes (name, user, session, tags, metadata) are repeated on every row.
-- This file is pure discovery: what tables exist, how they're modeled, and how
-- the traces from 02-generate-traces.py landed.
--
-- Run (from the host, against the workshop container):
--   docker exec -i langfuse-hols-v4-clickhouse-1 clickhouse-client \
--     -u clickhouse --password clickhouse --multiquery < 03-clickhouse-explore.sql
--
-- NOTE: the ClickHouse schema is an internal implementation detail of Langfuse,
-- not a stable API — column names can change across major versions (v3 → v4 moved
-- everything from `traces` / `observations` to `events_full` / `events_core`). The
-- DESCRIBE output below is always the source of truth for your installed version.
-- ════════════════════════════════════════════════════════════════════════════

-- The default DB Langfuse migrates into
SHOW DATABASES;

-- 1) What tables did Langfuse create? Note the *MergeTree engines. The v3 tables
--    `traces` and `observations` are still created (the migrations keep them), but
--    v4 does not write to them — query 4 below proves it.
SELECT name, engine
FROM system.tables
WHERE database = 'default'
ORDER BY name;

-- 2) The three tables that matter for analytics
SELECT '── events_full ──' AS section;
DESCRIBE TABLE default.events_full;

SELECT '── events_core ──' AS section;
DESCRIBE TABLE default.events_core;

SELECT '── scores ──' AS section;
DESCRIBE TABLE default.scores;

-- 3) How are they engineered? (engine, sort key, partitioning)
--    events_core is a materialized-view copy of events_full with truncated
--    input / output / metadata — the cheap table to scan for analytics. Both are
--    ReplacingMergeTree(event_ts, is_deleted) sorted by
--    (project_id, toStartOfMinute(start_time), xxHash32(trace_id), span_id, start_time):
--    a time-bucketed prefix, so a start_time range prunes well, while a lookup by
--    trace_id alone has to visit every minute bucket.
SELECT
    name,
    engine,
    partition_key,
    sorting_key
FROM system.tables
WHERE database = 'default' AND name IN ('events_full', 'events_core', 'scores')
ORDER BY name;

-- 4) Row counts — did our generated data land? The last two rows are the evidence
--    that v4 writes somewhere else: the v3 tables stay empty.
SELECT 'events_full'  AS tbl, count() AS rows FROM default.events_full
UNION ALL
SELECT 'events_core'  AS tbl, count() AS rows FROM default.events_core
UNION ALL
SELECT 'scores'       AS tbl, count() AS rows FROM default.scores
UNION ALL
SELECT 'traces (v3)'       AS tbl, count() AS rows FROM default.traces
UNION ALL
SELECT 'observations (v3)' AS tbl, count() AS rows FROM default.observations;

-- 5) A trace is its ROOT ROW: is_app_root = true (parent_span_id is empty for
--    traces the SDK started). Its steps are the other rows with the same trace_id.
--    Every row, root or not, carries the trace attributes below.
SELECT
    trace_id,
    name,
    trace_name,
    user_id,
    session_id,
    tags,
    environment,
    start_time
FROM default.events_core FINAL
WHERE is_deleted = 0 AND is_app_root
ORDER BY start_time DESC
LIMIT 5;

-- 6) The observation tree for the most recent trace — its root row plus its child
--    rows, found by trace_id
--    (root span → retrieve-context → answer-generation → self-check)
SELECT
    e.type,
    e.name,
    e.is_app_root                                           AS is_root,
    e.provided_model_name                                   AS model,
    dateDiff('millisecond', e.start_time, e.end_time)       AS latency_ms,
    e.level,
    e.usage_details,
    e.cost_details
FROM default.events_core AS e FINAL
WHERE e.is_deleted = 0
  AND e.trace_id = (
        SELECT trace_id
        FROM default.events_core FINAL
        WHERE is_deleted = 0 AND is_app_root
        ORDER BY start_time DESC
        LIMIT 1)
ORDER BY e.start_time;

-- 7) Scores attached to traces (user feedback + automated checks). A score points at
--    its trace with scores.trace_id — the same value as events_core.trace_id.
SELECT
    name,
    data_type,
    count()        AS n,
    round(avg(value), 3) AS avg_value
FROM default.scores
GROUP BY name, data_type
ORDER BY name;

-- 8) ReplacingMergeTree gotcha: rows are replaced, not updated. A row sent again with
--    the same sort key (e.g. an SDK retry) is stored twice until a background merge
--    collapses it; the dedup key is the sort key, `event_ts` picks the newest
--    version and `is_deleted` flags deletes.
--    → Plain count() can over-count; `FINAL` + `is_deleted = 0` gives the truth.
--    (v4's events tables are written once per span, so on SDK-only data the two
--    numbers are usually equal — `FINAL` is the habit that keeps them right when
--    they are not.)
SELECT
    count()                                       AS raw_rows,           -- may be inflated
    (SELECT count() FROM default.events_full FINAL WHERE is_deleted = 0) AS deduped_active
FROM default.events_full;

-- 9) How ClickHouse partitions the data (Langfuse uses monthly partitions on
--    the time column — the basis for fast time-range pruning and data retention).
SELECT
    table,
    partition,
    sum(rows)               AS rows,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE database = 'default'
  AND table IN ('events_full', 'events_core', 'scores')
  AND active
GROUP BY table, partition
ORDER BY table, partition;
