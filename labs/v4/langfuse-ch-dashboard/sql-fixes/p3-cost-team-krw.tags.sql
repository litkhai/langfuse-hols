-- p3, fix A · team from the tag `team:<name>` instead of the metadata arrays (tags is a far smaller column)
SELECT
    toStartOfDay(start_time, 'Asia/Seoul') AS time,
    substring(arrayFirst(x -> startsWith(x, 'team:'), tags), 6) AS team,
    round(sum(calculated_total_cost) * ${krw_per_usd}, 0) AS cost_krw
FROM ${db}.events_core
WHERE project_id = '${project}'
  AND environment IN (${environment:singlequote})
  AND type = 'GENERATION'
  AND $__timeFilter(start_time)
GROUP BY time, team
ORDER BY time, team
