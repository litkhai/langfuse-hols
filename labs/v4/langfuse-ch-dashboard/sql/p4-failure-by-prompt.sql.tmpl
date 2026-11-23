-- p4 · failure rate and judge score per prompt version (generations; ERROR level = failed)
SELECT
    prompt_name AS prompt,
    prompt_version AS version,
    formatDateTime(min(g.start_time), '%m-%d %H:%i', 'Asia/Seoul') AS first_seen_kst,
    count() AS generations,
    countIf(level = 'ERROR') AS failed,
    round(100 * countIf(level = 'ERROR') / count(), 2) AS failure_pct,
    round(avg(j.judge), 3) AS judge_avg
FROM ${db}.events_core AS g
LEFT JOIN
(
    SELECT trace_id, avg(value) AS judge
    FROM ${db}.scores
    WHERE project_id = '${project}'
      AND name = 'judge-faithfulness'
      AND $__timeFilter(timestamp)
    GROUP BY trace_id
) AS j ON j.trace_id = g.trace_id
WHERE g.project_id = '${project}'
  AND g.environment IN (${environment:singlequote})
  AND g.type = 'GENERATION'
  AND g.prompt_name != ''
  AND $__timeFilter(g.start_time)
GROUP BY prompt, version
ORDER BY prompt, version
SETTINGS join_use_nulls = 1  -- traces without a judge score stay NULL, not 0
