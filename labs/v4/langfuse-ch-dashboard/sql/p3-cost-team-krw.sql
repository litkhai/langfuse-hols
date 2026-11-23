-- p3 · model cost per KST day per team, in KRW (Langfuse's USD cost × the krw_per_usd variable)
-- `team` is trace metadata (langfuse.trace.metadata.team); v4 copies it onto every observation,
-- so no join back to the trace is needed.
SELECT
    toStartOfDay(start_time, 'Asia/Seoul') AS time,
    metadata_values[indexOf(metadata_names, 'team')] AS team,
    round(sum(calculated_total_cost) * ${krw_per_usd}, 0) AS cost_krw
FROM ${db}.events_core
WHERE project_id = '${project}'
  AND environment IN (${environment:singlequote})
  AND type = 'GENERATION'
  AND $__timeFilter(start_time)
GROUP BY time, team
ORDER BY time, team
