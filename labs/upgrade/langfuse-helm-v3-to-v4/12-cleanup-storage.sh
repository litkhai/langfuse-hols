#!/usr/bin/env bash
# 12 — optional storage cleanup after the cutover: drop the backfill scratch table, truncate the
# old tables (TRUNCATE, not DROP: Langfuse expects them). Irreversible; the old tables are the last
# way back to a v3 read path.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
size() { v2_ch -q "SELECT table, formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE active AND database='default' AND table IN ('traces','observations','events_full','events_core','observations_pid_tid_sorting') GROUP BY table ORDER BY table FORMAT TSV"; }
log "before"; size

{ cat modes/events_only.env; echo LANGFUSE_BACKGROUND_MIGRATION_V4_DROP_PID_TID_SORTING_TABLES=true; } >"$WORK/cleanup.env"
kx -n "$NS" create configmap langfuse-v4-migration --from-env-file="$WORK/cleanup.env" --dry-run=client -o yaml | kx apply -f - >/dev/null
kx -n "$NS" rollout restart deploy/"$V2"-worker >/dev/null; kx -n "$NS" rollout status deploy/"$V2"-worker --timeout=600s >/dev/null
for _ in $(seq 1 60); do
  [ "$(v2_psql -c "SELECT count(*) FROM background_migrations WHERE name LIKE '20260701_v4_step_5%' AND finished_at IS NOT NULL")" = 1 ] && break
  sleep 5
done
v2_psql -c "SELECT name, finished_at IS NOT NULL FROM background_migrations WHERE name LIKE '20260701_v4_step_5%'"
echo "scratch tables left: $(v2_ch -q "SELECT count() FROM system.tables WHERE database='default' AND name LIKE 'observations_pid_tid_sorting%'")"

cluster=$(kx -n "$NS" exec deploy/"$V2"-web -- printenv CLICKHOUSE_CLUSTER_ENABLED || echo false)
oc=""; [ "$cluster" = true ] && oc="ON CLUSTER default"
v2_ch -q "TRUNCATE TABLE traces $oc"; v2_ch -q "TRUNCATE TABLE observations $oc"
log "after"; size

url=$(pf app langfuse-app 3000); trap 'pf_stop app' EXIT
t=$(jq -r 'select(.phase=="v3-start") | .trace_id' "$WORK/sent.jsonl" | head -1)
echo "GET /api/public/v2/observations?traceId=<v3-era trace> after the truncate: $(api GET "/api/public/v2/observations?traceId=$t")," \
  "$(curl -s -u "$LF_PK:$LF_SK" "$url/api/public/v2/observations?traceId=$t" | jq '.data | length') observations"
