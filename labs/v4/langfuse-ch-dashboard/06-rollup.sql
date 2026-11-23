-- 06 — per-day cost rollup for panel p3 (fix B), in this lab's database only.
-- Target table + materialized view on the scaled copy, then a one-time backfill of what is already
-- there. Full treatment of rollups on Langfuse's tables (MV on default.events_core, rows Langfuse
-- rewrites, backfill without double counting) is the langfuse-ch-mv lab; this file only shows what the
-- dashboard reads afterwards.
CREATE TABLE IF NOT EXISTS lab_langfuse_ch_dashboard.cost_team_day
(
    project_id  String,
    environment LowCardinality(String),
    day_kst     Date,
    team        LowCardinality(String),
    service     LowCardinality(String),
    cost_usd    Decimal(38, 12),
    generations UInt64
)
ENGINE = SummingMergeTree
ORDER BY (project_id, environment, day_kst, team, service);

CREATE MATERIALIZED VIEW IF NOT EXISTS lab_langfuse_ch_dashboard.cost_team_day_mv
TO lab_langfuse_ch_dashboard.cost_team_day AS
SELECT project_id, environment, toDate(start_time, 'Asia/Seoul') AS day_kst,
       metadata_values[indexOf(metadata_names, 'team')] AS team, service_name AS service,
       sum(calculated_total_cost) AS cost_usd, count() AS generations
FROM lab_langfuse_ch_dashboard.events_core
WHERE type = 'GENERATION'
GROUP BY ALL;

TRUNCATE TABLE lab_langfuse_ch_dashboard.cost_team_day;

INSERT INTO lab_langfuse_ch_dashboard.cost_team_day
SELECT project_id, environment, toDate(start_time, 'Asia/Seoul') AS day_kst,
       metadata_values[indexOf(metadata_names, 'team')] AS team, service_name AS service,
       sum(calculated_total_cost) AS cost_usd, count() AS generations
FROM lab_langfuse_ch_dashboard.events_core
WHERE type = 'GENERATION'
GROUP BY ALL;
