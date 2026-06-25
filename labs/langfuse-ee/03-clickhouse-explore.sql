-- ════════════════════════════════════════════════════════════════════════════
-- 03-clickhouse-explore.sql
-- Peek inside Langfuse's ClickHouse backend.
--
-- Langfuse v3 stores its OLTP state (users, orgs, projects, prompts, audit log)
-- in Postgres, but every TRACE, OBSERVATION and SCORE lives in ClickHouse.
-- This file is pure discovery: what tables exist, how they're modeled, and how
-- the traces from 02-generate-traces.py landed.
--
-- Run (from the host, against the workshop container):
--   docker compose exec -T clickhouse clickhouse-client \
--     -u clickhouse --password clickhouse --multiquery < 03-clickhouse-explore.sql
--
-- NOTE: the ClickHouse schema is an internal implementation detail of Langfuse,
-- not a stable API — column names can change across major versions. The DESCRIBE
-- output below is always the source of truth for your installed version.
-- ════════════════════════════════════════════════════════════════════════════

-- The default DB Langfuse migrates into
SHOW DATABASES;

-- 1) What tables did Langfuse create? Note the *MergeTree engines.
SELECT name, engine
FROM system.tables
WHERE database = 'default'
ORDER BY name;

-- 2) The three tables that matter for analytics
SELECT '── traces ──' AS section;
DESCRIBE TABLE default.traces;

SELECT '── observations ──' AS section;
DESCRIBE TABLE default.observations;

SELECT '── scores ──' AS section;
DESCRIBE TABLE default.scores;

-- 3) How are they engineered? (engine, sort key, partitioning)
SELECT
    name,
    engine,
    partition_key,
    sorting_key
FROM system.tables
WHERE database = 'default' AND name IN ('traces', 'observations', 'scores')
ORDER BY name;

-- 4) Row counts — did our generated data land?
SELECT 'traces'       AS tbl, count() AS rows FROM default.traces
UNION ALL
SELECT 'observations' AS tbl, count() AS rows FROM default.observations
UNION ALL
SELECT 'scores'       AS tbl, count() AS rows FROM default.scores;

-- 5) A trace is one row; its steps are rows in `observations` joined by trace_id.
SELECT
    id,
    name,
    user_id,
    session_id,
    tags,
    environment,
    timestamp
FROM default.traces
ORDER BY timestamp DESC
LIMIT 5;

-- 6) The observation tree for the most recent trace
--    (root span → retrieve-context → answer-generation → self-check)
SELECT
    o.type,
    o.name,
    o.provided_model_name                                   AS model,
    dateDiff('millisecond', o.start_time, o.end_time)       AS latency_ms,
    o.level,
    o.usage_details,
    o.cost_details
FROM default.observations AS o
WHERE o.trace_id = (SELECT id FROM default.traces ORDER BY timestamp DESC LIMIT 1)
ORDER BY o.start_time;

-- 7) Scores attached to traces (user feedback + automated checks)
SELECT
    name,
    data_type,
    count()        AS n,
    round(avg(value), 3) AS avg_value
FROM default.scores
GROUP BY name, data_type
ORDER BY name;

-- 8) ReplacingMergeTree gotcha: Langfuse RE-INGESTS a row each time a trace is
--    updated (e.g. a span created, then updated with its output). Until a merge
--    collapses them, multiple versions sit on disk. The dedup key is the sort
--    key; `event_ts` picks the newest version and `is_deleted` flags deletes.
--    → Plain count() can over-count; `FINAL` + `is_deleted = 0` gives the truth.
SELECT
    count()                                       AS raw_rows,           -- may be inflated
    (SELECT count() FROM default.traces FINAL WHERE is_deleted = 0) AS deduped_active
FROM default.traces;

-- 9) How ClickHouse partitions the data (Langfuse uses monthly partitions on
--    the time column — the basis for fast time-range pruning and data retention).
SELECT
    table,
    partition,
    sum(rows)               AS rows,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE database = 'default'
  AND table IN ('traces', 'observations', 'scores')
  AND active
GROUP BY table, partition
ORDER BY table, partition;
