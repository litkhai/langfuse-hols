-- 03-mv.sql — run by 03-mv.sh, which puts a time a little in the future into the CUTOFF placeholder below (a string literal, so this file parses as is).
-- Target tables and incremental materialized views in lab_langfuse_ch_mv. The views read FROM
-- default.events_full (the table Langfuse v4 writes every observation to) and keep only this lab's rows.
-- Drop the has(tags, 'lab:langfuse-ch-mv') filter to roll up a whole project.

CREATE DATABASE IF NOT EXISTS lab_langfuse_ch_mv;

-- 1) Hourly rollup per OpenTelemetry service.name (events_full.service_name), observation type and model.
CREATE TABLE lab_langfuse_ch_mv.obs_hourly_by_service
(
    project_id    String,
    hour          DateTime,
    service_name  LowCardinality(String),
    type          LowCardinality(String),
    model         LowCardinality(String),
    observations  SimpleAggregateFunction(sum, UInt64),
    errors        SimpleAggregateFunction(sum, UInt64),
    traces        SimpleAggregateFunction(sum, UInt64),   -- root observations: one per trace
    input_tokens  SimpleAggregateFunction(sum, UInt64),
    output_tokens SimpleAggregateFunction(sum, UInt64),
    total_tokens  SimpleAggregateFunction(sum, UInt64),
    cost_usd      SimpleAggregateFunction(sum, Decimal(38, 12)),
    latency_ms    AggregateFunction(quantilesTDigest(0.5, 0.95, 0.99), UInt32)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (project_id, hour, service_name, type, model);

-- 2) Hourly rollup per trace tag: one row of events_full counts once for each of its tags.
CREATE TABLE lab_langfuse_ch_mv.obs_hourly_by_tag
(
    project_id    String,
    hour          DateTime,
    tag           LowCardinality(String),
    type          LowCardinality(String),
    observations  SimpleAggregateFunction(sum, UInt64),
    errors        SimpleAggregateFunction(sum, UInt64),
    traces        SimpleAggregateFunction(sum, UInt64),   -- root observations: one per trace
    total_tokens  SimpleAggregateFunction(sum, UInt64),
    cost_usd      SimpleAggregateFunction(sum, Decimal(38, 12)),
    latency_ms    AggregateFunction(quantilesTDigest(0.5, 0.95, 0.99), UInt32)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (project_id, hour, tag, type);

-- 3) A copy of every observation of traces tagged review:needed, with the full input and output
--    (events_core keeps 200 characters of each). Sorted by day, then trace: a time window and a trace
--    lookup within a day both use the key (05 measured a trace-first key). ReplacingMergeTree on
--    event_ts so that a row Langfuse writes twice (an exporter retry, 07) collapses on merge or FINAL.
CREATE TABLE lab_langfuse_ch_mv.review_observations
(
    project_id     String,
    trace_id       String,
    span_id        String,
    parent_span_id String,
    start_time     DateTime64(6),
    end_time       Nullable(DateTime64(6)),
    service_name   LowCardinality(String),
    trace_name     String,
    name           String,
    type           LowCardinality(String),
    level          LowCardinality(String),
    status_message String,
    user_id        String,
    session_id     String,
    tags           Array(String),
    model          LowCardinality(String),
    total_tokens   UInt64,
    cost_usd       Decimal(18, 12),
    input          String CODEC(ZSTD(3)),
    output         String CODEC(ZSTD(3)),
    event_ts       DateTime64(6),
    copied_at      DateTime64(3) DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(event_ts)
PARTITION BY toYYYYMM(start_time)
ORDER BY (project_id, toDate(start_time), trace_id, span_id);

-- The views. created_at >= toDateTime64('{CUTOFF}', 6): rows written before the cutoff come from the backfill in 03-mv.sh,
-- rows written after it from the view, so no row is counted twice or missed.
CREATE MATERIALIZED VIEW lab_langfuse_ch_mv.obs_hourly_by_service_mv TO lab_langfuse_ch_mv.obs_hourly_by_service AS
SELECT
    project_id,
    toStartOfHour(start_time)                                   AS hour,
    service_name,
    type,
    provided_model_name                                         AS model,
    count()                                                     AS observations,
    countIf(level = 'ERROR')                                    AS errors,
    countIf(parent_span_id = '')                                AS traces,
    sum(usage_details['input'])                                 AS input_tokens,
    sum(usage_details['output'])                                AS output_tokens,
    sum(usage_details['total'])                                 AS total_tokens,
    sum(cost_details['total'])                                  AS cost_usd,
    quantilesTDigestStateIf(0.5, 0.95, 0.99)(
        toUInt32(greatest(dateDiff('millisecond', start_time, end_time), 0)), end_time IS NOT NULL) AS latency_ms
FROM default.events_full
WHERE has(tags, 'lab:langfuse-ch-mv') AND is_deleted = 0 AND created_at >= toDateTime64('{CUTOFF}', 6)
GROUP BY project_id, hour, service_name, type, model;

CREATE MATERIALIZED VIEW lab_langfuse_ch_mv.obs_hourly_by_tag_mv TO lab_langfuse_ch_mv.obs_hourly_by_tag AS
SELECT
    project_id,
    toStartOfHour(start_time)                                   AS hour,
    arrayJoin(arrayFilter(t -> t != 'lab:langfuse-ch-mv', tags)) AS tag,
    type,
    count()                                                     AS observations,
    countIf(level = 'ERROR')                                    AS errors,
    countIf(parent_span_id = '')                                AS traces,
    sum(usage_details['total'])                                 AS total_tokens,
    sum(cost_details['total'])                                  AS cost_usd,
    quantilesTDigestStateIf(0.5, 0.95, 0.99)(
        toUInt32(greatest(dateDiff('millisecond', start_time, end_time), 0)), end_time IS NOT NULL) AS latency_ms
FROM default.events_full
WHERE has(tags, 'lab:langfuse-ch-mv') AND is_deleted = 0 AND created_at >= toDateTime64('{CUTOFF}', 6)
GROUP BY project_id, hour, tag, type;

CREATE MATERIALIZED VIEW lab_langfuse_ch_mv.review_observations_mv TO lab_langfuse_ch_mv.review_observations AS
SELECT
    project_id, trace_id, span_id, parent_span_id, start_time, end_time, service_name, trace_name, name, type,
    level, status_message, user_id, session_id, tags,
    provided_model_name         AS model,
    usage_details['total']      AS total_tokens,
    cost_details['total']       AS cost_usd,
    input, output, event_ts
FROM default.events_full
WHERE has(tags, 'lab:langfuse-ch-mv') AND has(tags, 'review:needed') AND is_deleted = 0 AND created_at >= toDateTime64('{CUTOFF}', 6);
