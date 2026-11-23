-- p2 · trace latency p50 / p95 per KST day per service, in seconds (root observation duration)
SELECT
    toStartOfDay(start_time, 'Asia/Seoul') AS time,
    service_name,
    round(quantile(0.5)(dateDiff('millisecond', start_time, end_time)) / 1000, 2) AS p50,
    round(quantile(0.95)(dateDiff('millisecond', start_time, end_time)) / 1000, 2) AS p95
FROM ${db}.events_core
WHERE project_id = '${project}'
  AND environment IN (${environment:singlequote})
  AND parent_span_id = ''
  AND end_time IS NOT NULL
  AND $__timeFilter(start_time)
GROUP BY time, service_name
ORDER BY time, service_name
