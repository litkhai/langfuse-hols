-- p7 · score trend per KST day per service: judge-faithfulness average and user-feedback 👍 rate
-- Scores carry no service, so the trace's root observation supplies it (join on trace_id).
SELECT
    toStartOfDay(s.timestamp, 'Asia/Seoul') AS time,
    t.service_name AS service,
    round(avgIf(s.value, s.name = 'judge-faithfulness'), 3) AS judge_avg,
    round(avgIf(s.value, s.name = 'user-feedback'), 3) AS thumbs_up_rate
FROM ${db}.scores AS s
INNER JOIN
(
    SELECT trace_id, service_name
    FROM ${db}.events_core
    WHERE project_id = '${project}'
      AND environment IN (${environment:singlequote})
      AND parent_span_id = ''
      AND $__timeFilter(start_time)
) AS t ON t.trace_id = s.trace_id
WHERE s.project_id = '${project}'
  AND s.name IN ('judge-faithfulness', 'user-feedback')
  AND $__timeFilter(s.timestamp)
GROUP BY time, service
ORDER BY time, service
