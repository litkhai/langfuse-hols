#!/usr/bin/env bash
# 07 — initial copy of v3's ClickHouse data into langfuse_v4, then v4's own historic backfill
# (background migrations 20260701_v4_step_1..4) turns the copied traces and observations into
# events_full. Then v4 must show the old traces.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
chain="name LIKE '20260701_v4_step_%' AND name NOT LIKE '%step_5%'"

log "columns v3 has and v4 does not (not copied), per table"
for t in traces observations scores dataset_run_items_rmt blob_storage_file_log; do
  echo "$t: $(ch -q "SELECT arrayStringConcat(groupArray(name), ' ') FROM system.columns WHERE database='default' AND table='$t' AND name NOT IN (SELECT name FROM system.columns WHERE database='langfuse_v4' AND table='$t')")"
done
echo "v3 tables not copied: $(ch -q "SELECT arrayStringConcat(groupArray(name), ' ') FROM system.tables WHERE database='default' AND name NOT IN ('traces','observations','scores','dataset_run_items_rmt','blob_storage_file_log','schema_migrations')")"

log "initial copy"
t0=$(now); ./copy-ch.sh initial | tee "$WORK/copy-initial.txt"; echo "initial copy: $(elapsed "$t0") s"

log "historic backfill on v4: gate on, worker restarted"
t0=$(now)
v4env "LANGFUSE_BACKGROUND_MIGRATION_V4_ENABLE_HISTORIC_BACKFILL=true"
kx -n "$NS" rollout restart deploy/"$V4"-langfuse-worker >/dev/null
kx -n "$NS" rollout status deploy/"$V4"-langfuse-worker --timeout=600s >/dev/null
for _ in $(seq 1 180); do
  [ "$(psql_ langfuse_v4 -c "SELECT count(*) FROM background_migrations WHERE $chain AND finished_at IS NULL AND failed_at IS NULL")" = 0 ] && break
  sleep 5
done
echo "backfill steps 1-4: $(elapsed "$t0") s (gate on to last step finished)"
psql_ langfuse_v4 -c "SELECT name, finished_at IS NOT NULL AS finished, failed_at IS NOT NULL AS failed, left(coalesce(failed_reason,''),100) FROM background_migrations WHERE name LIKE '20260701_v4%' ORDER BY name"
check "failed backfill steps" "$(psql_ langfuse_v4 -c "SELECT count(*) FROM background_migrations WHERE name LIKE '20260701_v4%' AND failed_at IS NOT NULL")" 0

log "v3 (default) vs v4 (langfuse_v4)"
v3t=$(ch -q "SELECT uniqExact(id) FROM default.traces FINAL")
v3o=$(ch -q "SELECT uniqExact(id) FROM default.observations FINAL")
v3s=$(ch -q "SELECT uniqExact(id) FROM default.scores FINAL")
check "traces: v3 vs distinct trace_id in v4 events_full" "$(ch -q 'SELECT uniqExact(trace_id) FROM langfuse_v4.events_full')" "$v3t"
check "traces of v3 without a row in v4 events_full" \
  "$(ch -q 'SELECT count() FROM (SELECT id FROM default.traces FINAL) t LEFT ANTI JOIN (SELECT DISTINCT trace_id FROM langfuse_v4.events_full) e ON t.id = e.trace_id')" 0
check "observations of v3 missing from v4 events_full" \
  "$(ch -q 'SELECT count() FROM (SELECT id FROM default.observations FINAL) o LEFT ANTI JOIN (SELECT span_id FROM langfuse_v4.events_full) e ON o.id = e.span_id')" 0
check "scores: v3 vs v4" "$(ch -q 'SELECT uniqExact(id) FROM langfuse_v4.scores FINAL')" "$v3s"
echo "v3 traces $v3t, observations $v3o, scores $v3s; v4 events_full rows $(ch -q 'SELECT count() FROM langfuse_v4.events_full FINAL'), virtual roots $(ch -q "SELECT count() FROM langfuse_v4.events_full FINAL WHERE startsWith(span_id, 't-')")"
ch -q "SELECT database, table, formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE active AND database IN ('default','langfuse_v4') AND table IN ('traces','observations','scores','events_full','events_core','observations_pid_tid_sorting') GROUP BY database, table ORDER BY database, table FORMAT TSV"

log "old traces through v4's API"
url=$(pf v4 "$V4"-langfuse-web 3000); trap 'pf_stop v4' EXIT
t=$(jq -r 'select(.phase=="v3-start" and (.producer|startswith("python-sdk"))) | .trace_id' "$WORK/sent.jsonl" | head -1)
check "GET /api/public/v2/observations?traceId=<v3 trace>" "$(api "$url" GET "/api/public/v2/observations?traceId=$t")" 200
apij "$url" "/api/public/v2/observations?traceId=$t&fields=core,basic" | jq -c '[.data[] | {name, type}] | sort_by(.name)'
check "observations of it on v4 (virtual root + SDK root + 2 children)" "$(apij "$url" "/api/public/v2/observations?traceId=$t" | jq '.data | length')" 4
check "GET /api/public/v3/scores?traceId=<v3 trace>" "$(apij "$url" "/api/public/v3/scores?traceId=$t" | jq '.data | length')" 1
lt=$(jq -r 'select(.phase=="v3-start" and .producer=="legacy-http") | .trace_id' "$WORK/sent.jsonl" | head -1)
check "legacy-API trace from v3: observations on v4 (virtual root + generation)" "$(apij "$url" "/api/public/v2/observations?traceId=$lt" | jq '.data | length')" 2
check "GET /api/public/experiments (the v3 experiment run)" \
  "$(apij "$url" '/api/public/experiments?fromStartTime=2026-01-01T00:00:00Z' | jq '.data | length')" 1
check "GET /api/public/v2/prompts/support-system" "$(api "$url" GET /api/public/v2/prompts/support-system)" 200
check "GET /api/public/v2/datasets/support-golden" "$(api "$url" GET /api/public/v2/datasets/support-golden)" 200
"$PY" ui.py login "$url" "$WORK/v4.jar" >/dev/null
"$PY" ui.py trpc "$url" "$WORK/v4.jar" traces.byIdWithObservationsAndScores "{\"projectId\":\"$LF_PROJECT\",\"traceId\":\"$t\"}" --query \
  | jq -c '{http, name: .body[0].result.data.json.name, observations: (.body[0].result.data.json.observations | length?), scores: (.body[0].result.data.json.scores | length?), error: .body[0].error.json.message}'
exit $fail
