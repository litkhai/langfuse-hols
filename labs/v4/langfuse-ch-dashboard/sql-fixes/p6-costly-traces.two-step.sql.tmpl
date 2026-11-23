-- p6, fix · find the 20 trace ids on the narrow columns first, then read the wide ones for those 20 only
-- (the second pass uses the bloom_filter skip index idx_trace_id of events_core: EXPLAIN indexes = 1 kept
-- 34 of 1,844 granules for two ids on the ×1000 copy, 2026-11-23)
WITH top AS
(
    SELECT trace_id
    FROM ${db}.events_core
    WHERE project_id = '${project}'
      AND environment IN (${environment:singlequote})
      AND type = 'GENERATION'
      AND $__timeFilter(start_time)
    GROUP BY trace_id
    ORDER BY sum(calculated_total_cost) DESC, trace_id
    LIMIT 20
)
SELECT
    trace_id,
    formatDateTime(min(start_time), '%m-%d %H:%i:%S', 'Asia/Seoul') AS start_kst,
    any(service_name) AS service,
    any(metadata_values[indexOf(metadata_names, 'team')]) AS team,
    any(user_id) AS user_id,
    sum(usage_details['input']) AS input_tokens,
    sum(usage_details['output']) AS output_tokens,
    round(sum(calculated_total_cost) * ${krw_per_usd}, 1) AS cost_krw
FROM ${db}.events_core
WHERE project_id = '${project}'
  AND environment IN (${environment:singlequote})
  AND type = 'GENERATION'
  AND $__timeFilter(start_time)
  AND trace_id IN (SELECT trace_id FROM top)
GROUP BY trace_id
ORDER BY cost_krw DESC, trace_id
LIMIT 20
