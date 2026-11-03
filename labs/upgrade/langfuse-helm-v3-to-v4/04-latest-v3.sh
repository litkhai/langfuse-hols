#!/usr/bin/env bash
# 04 — latest v3 on chart v1, and the background-migration gate. The chart migration needs
# 3.224.1 or later on the source, and v4 needs every background migration finished.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
bm() { v1_psql -c "SELECT name, finished_at IS NOT NULL AS finished, failed_at IS NOT NULL AS failed, args->>'envGate' AS env_gate FROM background_migrations ORDER BY name"; }

log "background migrations on the running version (before)"
bm

log "helm upgrade $V1 chart $CHART_V1 (unchanged), Langfuse -> $LF_V3"
hx upgrade "$V1" "$CHART" --version "$CHART_V1" -n "$NS" -f v1-values.yaml \
  --set langfuse.image.tag="$LF_V3" --wait --timeout 15m
kx -n "$NS" rollout status deploy/"$V1"-web --timeout=600s

# The worker looks for background migrations once, at start. web inserts new rows while it
# applies its Prisma migrations, so a worker that started first misses them (seen on
# 3.172.1 -> 3.225.15: 20261022_encrypt_legacy_webhook_headers stayed pending). Restart it
# after web is up.
log "restart the worker after web has applied its migrations"
kx -n "$NS" rollout restart deploy/"$V1"-worker
kx -n "$NS" rollout status deploy/"$V1"-worker --timeout=600s

# The gate. The upstream query (finished_at IS NULL -> 0 rows) never reaches 0 on 3.225.x:
# the v4 backfill chain ships there as rows gated by args.envGate, dormant on purpose. Gated
# rows are left out; anything else unfinished or failed blocks v4.
gate="SELECT count(*) FROM background_migrations WHERE finished_at IS NULL AND NOT (args ? 'envGate')"
log "wait until every non-gated background migration has finished"
for _ in $(seq 1 60); do [ "$(v1_psql -c "$gate")" = 0 ] && break; sleep 10; done
bm
echo "unfinished, not gated: $(v1_psql -c "$gate")  (must be 0)"
echo "failed: $(v1_psql -c "SELECT count(*) FROM background_migrations WHERE failed_at IS NOT NULL")  (must be 0)"

log "ClickHouse schema version on $LF_V3"
v1_ch -q "SELECT version, dirty FROM schema_migrations ORDER BY sequence DESC LIMIT 1"

url=$(pf app langfuse-app 3000); trap 'pf_stop app' EXIT
curl -s "$url/api/public/health"; echo
