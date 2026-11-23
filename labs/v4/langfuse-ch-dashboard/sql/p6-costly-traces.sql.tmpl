-- p6 · the 20 costliest traces in range, in KRW (sum over the trace's generations)
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
GROUP BY trace_id
ORDER BY cost_krw DESC, trace_id
LIMIT 20
