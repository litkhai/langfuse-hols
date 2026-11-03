#!/usr/bin/env bash
# 10 — the historic backfill, with the dual write active and healthy (08). Everything that only
# exists in the old tables (all of v3, and what v3 wrote during the 09 rehearsal) moves to events_full.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1: $2"; else echo "FAIL  $1: expected $3, got $2"; fail=1; fi; }
bm() { v2_psql -c "SELECT name, finished_at IS NOT NULL AS finished, failed_at IS NOT NULL AS failed, left(coalesce(failed_reason,''),120) FROM background_migrations WHERE name LIKE '20260701_v4%' ORDER BY name"; }

log "before"
echo "traces $(v2_ch -q 'SELECT count() FROM traces FINAL') · observations $(v2_ch -q 'SELECT count() FROM observations FINAL') · events_full traces $(v2_ch -q 'SELECT uniqExact(trace_id) FROM events_full') rows $(v2_ch -q 'SELECT count() FROM events_full FINAL')"
v2_ch -q "SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE active AND database='default'" | sed 's/^/ClickHouse default db on disk: /'

log "enable the backfill"
t0=$(date +%s)
setmode dual-backfill
for _ in $(seq 1 180); do
  left=$(v2_psql -c "SELECT count(*) FROM background_migrations WHERE name LIKE '20260701_v4_step_%' AND name NOT LIKE '%step_5%' AND finished_at IS NULL AND failed_at IS NULL")
  [ "$left" = 0 ] && break
  sleep 10
done
echo "backfill steps 1-4 done after $(( $(date +%s) - t0 ))s"
bm
check "failed backfill steps" "$(v2_psql -c "SELECT count(*) FROM background_migrations WHERE name LIKE '20260701_v4%' AND failed_at IS NOT NULL")" 0
v2_ch -q "SELECT name, formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE active AND database='default' AND name IN ('traces','observations','events_full','events_core','observations_pid_tid_sorting') GROUP BY name ORDER BY name FORMAT TSV" 2>/dev/null \
  || v2_ch -q "SELECT table, formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE active AND database='default' AND table IN ('traces','observations','events_full','events_core','observations_pid_tid_sorting') GROUP BY table ORDER BY table FORMAT TSV"

log "after: every trace and observation of the old tables has a row in events_full"
check "traces without a root in events_full" \
  "$(v2_ch -q 'SELECT count() FROM (SELECT id FROM traces FINAL) t LEFT ANTI JOIN (SELECT DISTINCT trace_id FROM events_full) e ON t.id = e.trace_id')" 0
check "observations missing from events_full" \
  "$(v2_ch -q 'SELECT count() FROM (SELECT id FROM observations FINAL) o LEFT ANTI JOIN (SELECT span_id FROM events_full) e ON o.id = e.span_id')" 0
# Virtual root spans: span id t-<trace_id>, type SPAN, empty parent (upgrade guide, "The new data model").
echo "virtual root spans: $(v2_ch -q "SELECT count() FROM events_full FINAL WHERE startsWith(span_id, 't-')")"
# Trace metadata is not copied to the child events by the backfill (the guide says so); check it.
t=$(jq -r 'select(.phase=="v3-start" and (.producer|startswith("python-sdk-3"))) | .trace_id' "$WORK/sent.jsonl" | head -1)
v2_ch -q "SELECT name, span_id = concat('t-', trace_id) AS virtual_root, user_id, session_id, metadata_names FROM events_full FINAL WHERE trace_id = '$t' ORDER BY start_time FORMAT PrettyCompactMonoBlock"
exit $fail
