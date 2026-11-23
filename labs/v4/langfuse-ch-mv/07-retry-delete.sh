#!/usr/bin/env bash
# 07-retry-delete.sh — two things a materialized view does not see the way Langfuse does. Run after 03.
#
#   1. An exporter retry: 07-retry.py sends one trace (2 spans) twice with the same span ids. Langfuse writes
#      both; events_full (ReplacingMergeTree) shows them once after a merge or with FINAL, the views
#      counted both inserts.
#   2. A trace deleted in Langfuse (DELETE /api/public/traces/<id>): Langfuse deletes its rows from
#      events_full and events_core with DELETE FROM (a lightweight delete, not an insert), so the views are
#      not told; the copy keeps the trace's input and output.
# Then 04-check.sh, which is expected to FAIL here; 08-repair.sh repairs.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OUT="$RESULTS/07-retry-delete.txt"
exec > >(tee "$OUT") 2>&1
echo "# 07-retry-delete.sh, $(date -u +%FT%TZ)"

echo "## 1. exporter retry"
T=$("$PY" "$HERE/07-retry.py" | tee /dev/stderr | tail -1)
until [[ "$(ch "SELECT count() FROM default.events_full WHERE trace_id = '$T'")" -ge 2 ]]; do sleep 2; done
sleep 30   # 07-retry.py returns after both exports; 30 s for the worker to write the second
ch "SELECT 'events_full' AS t, count() AS rows FROM default.events_full WHERE trace_id = '$T'
    UNION ALL SELECT 'events_full FINAL', count() FROM default.events_full FINAL WHERE trace_id = '$T'
    UNION ALL SELECT 'review_observations', count() FROM $LAB_DB.review_observations WHERE trace_id = '$T'
    UNION ALL SELECT 'review_observations FINAL', count() FROM $LAB_DB.review_observations FINAL WHERE trace_id = '$T'" PrettyCompactMonoBlock
echo "inserts of exactly 2 rows into events_full, last 5 min (a retry can also share an insert with other rows):"
ch "SELECT event_time, written_rows FROM system.query_log WHERE type = 'QueryFinish' AND query_kind = 'Insert'
    AND has(tables, 'default.events_full') AND event_time > now() - INTERVAL 5 MINUTE AND written_rows = 2
    ORDER BY event_time" PrettyCompactMonoBlock

echo "## 2. trace deleted in Langfuse"
D=$(ch "SELECT trace_id FROM default.events_full FINAL WHERE has(tags, '$LAB_TAG') AND has(tags, 'review:needed')
        AND parent_span_id = '' AND service_name = 'policy-qa' ORDER BY start_time LIMIT 1")
echo "trace $D: $(ch "SELECT count() FROM default.events_full WHERE trace_id = '$D'") rows in events_full, $(ch "SELECT count() FROM $LAB_DB.review_observations WHERE trace_id = '$D'") in the copy"
curl -sS -X DELETE -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" "$LANGFUSE_HOST/api/public/traces/$D"; echo
t0=$(date +%s)
until [[ "$(ch "SELECT count() FROM default.events_full WHERE trace_id = '$D'")" == 0 ]]; do
  (( $(date +%s) - t0 > 300 )) && { echo "✗ still in events_full after 300 s"; break; }; sleep 5
done
echo "gone from events_full after $(( $(date +%s) - t0 )) s (polled every 5 s)"
ch "SELECT query_kind, substring(replaceRegexpAll(query, '\\s+', ' '), 1, 60) AS query FROM system.query_log
    WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 10 MINUTE AND query LIKE 'DELETE FROM events_%'
    AND query LIKE '%$D%' ORDER BY event_time" PrettyCompactMonoBlock
echo "still in the copy: $(ch "SELECT count() FROM $LAB_DB.review_observations WHERE trace_id = '$D'") rows, input of the root: $(ch "SELECT any(input) FROM $LAB_DB.review_observations WHERE trace_id = '$D' AND parent_span_id = ''")"
echo "## 04-check.sh now (FAIL expected)"
"$HERE/04-check.sh"; echo "04-check.sh exit code: $?"
