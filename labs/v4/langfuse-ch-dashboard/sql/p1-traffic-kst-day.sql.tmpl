-- p1 · traces per KST day per service (root observations only: one row per trace)
-- events_core: PRIMARY KEY (project_id, toStartOfMinute(start_time), …), so the project and the
-- time filter prune granules before anything is read.
SELECT
    toStartOfDay(start_time, 'Asia/Seoul') AS time,
    service_name,
    count() AS traces
FROM ${db}.events_core
WHERE project_id = '${project}'
  AND environment IN (${environment:singlequote})
  AND parent_span_id = ''
  AND $__timeFilter(start_time)
GROUP BY time, service_name
ORDER BY time, service_name
