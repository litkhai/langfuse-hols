-- p5 · the 20 slowest traces in range; trace_id links back to the Langfuse trace page
SELECT
    trace_id,
    formatDateTime(start_time, '%m-%d %H:%i:%S', 'Asia/Seoul') AS start_kst,
    service_name AS service,
    user_id,
    round(dateDiff('millisecond', start_time, end_time) / 1000, 2) AS seconds,
    level,
    status_message
FROM ${db}.events_core
WHERE project_id = '${project}'
  AND environment IN (${environment:singlequote})
  AND parent_span_id = ''
  AND end_time IS NOT NULL
  AND $__timeFilter(start_time)
ORDER BY seconds DESC, trace_id
LIMIT 20
