-- p3, fix B · read a per-day rollup (06-rollup.sql) instead of the observations
SELECT
    toDateTime(day_kst, 'Asia/Seoul') AS time,
    team,
    round(sum(cost_usd) * ${krw_per_usd}, 0) AS cost_krw
FROM ${db}.cost_team_day
WHERE project_id = '${project}'
  AND environment IN (${environment:singlequote})
  AND $__timeFilter(day_kst)
GROUP BY time, team
ORDER BY time, team
