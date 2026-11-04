#!/usr/bin/env bash
# 09 — rollback rehearsal before the cutover: v4 (dual) -> latest v3 -> v4 (dual) again.
#  a) the image swap alone: v3 web must refuse to start (ClickHouse schema newer than its files)
#  b) back to v4, rewind the ClickHouse schema to 37 from inside the v4 web pod, then v3
#  c) on v3: data written while on v4 is readable through the v3 API
#  d) forward to v4 dual again (the schema migrations re-run; events tables start empty)
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1: $2"; else echo "FAIL  $1: expected $3, got $2"; fail=1; fi; }
schema() { v2_ch -q 'SELECT version FROM schema_migrations ORDER BY sequence DESC LIMIT 1'; }
to_v3() { hx upgrade "$V2" "$CHART" --version "$CHART_V2" -n "$NS" $(v2_values) --set langfuse.image.tag="$LF_V3" "$@"; }
to_v4() { hx upgrade "$V2" "$CHART" --version "$CHART_V2" -n "$NS" $(v2_values) -f v4-values.yaml --wait --timeout 15m
          kx -n "$NS" rollout status deploy/"$V2"-web --timeout=600s; kx -n "$NS" rollout restart deploy/"$V2"-worker
          kx -n "$NS" rollout status deploy/"$V2"-worker --timeout=600s; }

echo "schema version on v4: $(schema)"

log "a) image swap only: $LF_V4 -> $LF_V3 without a rewind"
to_v3
sleep 90
pod=$(kx -n "$NS" get pods -l app.kubernetes.io/instance="$V2",app=web --sort-by=.metadata.creationTimestamp -o name | tail -1)
kx -n "$NS" get "$pod" -o jsonpath='{.metadata.name} {.spec.containers[0].image} restarts={.status.containerStatuses[0].restartCount} ready={.status.containerStatuses[0].ready}{"\n"}'
kx -n "$NS" logs "$pod" --tail=200 | grep -m3 -i "no migration found" || { echo "FAIL  expected 'no migration found' in the v3 web log"; fail=1; }

log "b) back to v4, rewind ClickHouse to schema 37 with the v4 image's migrate binary, then v3"
to_v4
echo "schema version back on v4: $(schema)"
cluster=$(kx -n "$NS" exec deploy/"$V2"-web -- printenv CLICKHOUSE_CLUSTER_ENABLED || echo false)
echo "CLICKHOUSE_CLUSTER_ENABLED=$cluster"
if [ "$cluster" = true ]; then
  src=clustered; extra='&x-cluster-name=${CLICKHOUSE_CLUSTER_NAME:-default}&x-migrations-table-engine=ReplicatedMergeTree'
else
  src=unclustered; extra='&x-migrations-table-engine=MergeTree'
fi
# The command of the upgrade guide ("Rolling back without a restore"), run in the deployed v4 web pod.
kx -n "$NS" exec deploy/"$V2"-web -- sh -c "cd /app/packages/shared && migrate -source file://clickhouse/migrations/$src \
  -database \"\${CLICKHOUSE_MIGRATION_URL}?username=\${CLICKHOUSE_USER}&password=\${CLICKHOUSE_PASSWORD}&database=\${CLICKHOUSE_DB:-default}&x-multi-statement=true$extra\" goto 37" 2>&1 | tail -5
check "schema version after the rewind" "$(schema)" 37
echo "events tables after the rewind: $(v2_ch -q "SELECT count() FROM system.tables WHERE database='default' AND name IN ('events_full','events_core')")"
to_v3 --wait --timeout 15m
kx -n "$NS" rollout status deploy/"$V2"-web --timeout=600s
kx -n "$NS" rollout restart deploy/"$V2"-worker; kx -n "$NS" rollout status deploy/"$V2"-worker --timeout=600s

log "c) on v3 again"
url=$(pf app langfuse-app 3000); trap 'pf_stop app' EXIT
export LANGFUSE_HOST=$url LANGFUSE_PUBLIC_KEY=$LF_PK LANGFUSE_SECRET_KEY=$LF_SK
curl -s "$url/api/public/health"; echo
t=$(jq -r 'select(.phase=="v4-dual" and (.producer|startswith("python-sdk-4"))) | .trace_id' "$WORK/sent.jsonl" | head -1)
check "GET /api/public/traces/<trace written on v4 dual by SDK v4>" "$(api GET "/api/public/traces/$t")" 200
"$PY" produce.py traces --phase v3-rollback --n 5

log "d) forward again: v4, dual"
setmode dual >/dev/null
to_v4
setmode dual
echo "schema version: $(schema) · events_full rows: $(v2_ch -q 'SELECT count() FROM events_full')"
exit $fail
