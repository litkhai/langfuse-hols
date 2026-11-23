#!/usr/bin/env bash
# 08-repair.sh — bring the views' tables back in line with events_full after 07 (or any retry or delete).
#
# Rollups: find the hours whose observations, tokens or cost differ from events_full FINAL, delete those
# hours from the rollup and insert them again from events_full FINAL with the view's own SELECT
# (lib.sh view_insert). Copy: delete the rows whose observation is no longer in events_full (a trace deleted
# in Langfuse, or removed by retention). Rebuild only hours that are closed: rows of the current hour that
# arrive during the rebuild would be counted by the view and by the rebuild.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
W="has(tags, '$LAB_TAG') AND is_deleted = 0"

hours() {   # hours() <rollup> → 'YYYY-MM-DD HH:00:00', … of the hours that differ
  ch "SELECT arrayStringConcat(groupArray(concat('''', toString(hour), '''')), ', ') FROM (
        SELECT hour FROM (
          SELECT toDateTime(toStartOfHour(start_time)) AS hour, count() c, sum(usage_details['total']) tok, sum(cost_details['total']) cost
          FROM default.events_full FINAL WHERE $W GROUP BY hour) r
        FULL OUTER JOIN (
          SELECT hour, sum(observations) c, sum(total_tokens) tok, sum(cost_usd) cost
          FROM $LAB_DB.$1 $( [[ $1 == obs_hourly_by_tag ]] && echo "WHERE tag LIKE 'svc:%'" ) GROUP BY hour) m USING hour
        WHERE r.c != m.c OR r.tok != m.tok OR r.cost != m.cost ORDER BY hour)" TSVRaw
}
for t in obs_hourly_by_service obs_hourly_by_tag; do
  h=$(hours "$t")
  if [[ -z "$h" ]]; then echo "$t: no hour differs"; continue; fi
  echo "$t: rebuilding hours $h"
  ch "DELETE FROM $LAB_DB.$t WHERE hour IN ($h)"
  view_insert "$t" "toStartOfHour(start_time) IN ($h)"
done

gone=$(ch "SELECT count() FROM $LAB_DB.review_observations
           WHERE (project_id, trace_id, span_id) NOT IN (SELECT project_id, trace_id, span_id FROM default.events_full WHERE $W)")
echo "review_observations: $gone rows whose observation is gone from events_full"
if [[ "$gone" != 0 ]]; then
  ch "DELETE FROM $LAB_DB.review_observations
      WHERE (project_id, trace_id, span_id) NOT IN (SELECT project_id, trace_id, span_id FROM default.events_full WHERE $W)"
fi
