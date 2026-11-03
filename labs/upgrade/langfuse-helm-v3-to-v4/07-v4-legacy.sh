#!/usr/bin/env bash
# 07 — server v3 -> v4 in `legacy` mode: the schema migrations run, the behaviour stays v3.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1: $2"; else echo "FAIL  $1: expected $3, got $2"; fail=1; fi; }
tables_pg() { v2_psql -c "SELECT string_agg(tablename, ' ' ORDER BY tablename) FROM pg_tables WHERE schemaname='public' AND tablename IN ('traces','observations','scores','dataset_run_items')"; }
tables_ch() { v2_ch -q "SELECT arrayStringConcat(groupArray(name), ' ') FROM (SELECT name FROM system.tables WHERE database='default' AND name IN ('traces','observations','scores','event_log','project_environments','dataset_run_items','dataset_run_items_rmt','events_full','events_core','observations_batch_staging') ORDER BY name)"; }

log "gate (same as 04, now on the v2 release)"
check "unfinished, not gated background migrations" \
  "$(v2_psql -c "SELECT count(*) FROM background_migrations WHERE finished_at IS NULL AND NOT (args ? 'envGate')")" 0
check "failed background migrations" "$(v2_psql -c "SELECT count(*) FROM background_migrations WHERE failed_at IS NOT NULL")" 0

log "backup right before the server upgrade (Postgres dump; ClickHouse: see README)"
pw=$(kx -n "$NS" get secret "$V2-postgresql-auth" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
kx -n "$NS" exec "$V2-postgresql-0" -- env PGPASSWORD="$pw" pg_dump -U postgres -Fc langfuse >"$WORK/pg-before-v4.dump"
ls -l "$WORK/pg-before-v4.dump" | awk '{print "pg_dump", $5, "bytes"}'

log "before: schema version and tables"
echo "ClickHouse schema version $(v2_ch -q 'SELECT version FROM schema_migrations ORDER BY sequence DESC LIMIT 1')"
echo "Postgres: $(tables_pg)"; echo "ClickHouse: $(tables_ch)"

log "helm upgrade $V2: Langfuse $LF_V3 -> $LF_V4, write mode legacy"
kx -n "$NS" create configmap langfuse-v4-migration --from-env-file=modes/legacy.env --dry-run=client -o yaml | kx apply -f -
hx upgrade "$V2" "$CHART" --version "$CHART_V2" -n "$NS" $(v2_values) -f v4-values.yaml --wait --timeout 15m
kx -n "$NS" rollout status deploy/"$V2"-web --timeout=600s
kx -n "$NS" rollout restart deploy/"$V2"-worker; kx -n "$NS" rollout status deploy/"$V2"-worker --timeout=600s

log "after: schema version and tables"
echo "ClickHouse schema version $(v2_ch -q 'SELECT version FROM schema_migrations ORDER BY sequence DESC LIMIT 1')"
echo "Postgres: $(tables_pg)"; echo "ClickHouse: $(tables_ch)"
check "Postgres legacy tables left" "$(tables_pg)" ""
check "events_full rows (legacy writes none)" "$(v2_ch -q 'SELECT count() FROM events_full')" 0

url=$(pf app langfuse-app 3000); trap 'pf_stop app' EXIT
export LANGFUSE_HOST=$url LANGFUSE_PUBLIC_KEY=$LF_PK LANGFUSE_SECRET_KEY=$LF_SK
curl -s "$url/api/public/health"; echo
before=$(v2_ch -q "SELECT count() FROM traces FINAL")

log "producers on legacy: SDK v3, SDK v4, the legacy ingestion API"
"$PY" produce.py traces --phase v4-legacy --n 10
"$PY4" produce.py traces --phase v4-legacy --n 10
"$PY" produce.py legacy-http --phase v4-legacy --n 5
sleep 30
check "new rows in traces (old table)" "$(( $(v2_ch -q 'SELECT count() FROM traces FINAL') - before ))" 25
check "events_full rows" "$(v2_ch -q 'SELECT count() FROM events_full')" 0

log "v3 surfaces on legacy"
check "GET /api/public/traces" "$(api GET '/api/public/traces?limit=1')" 200
check "GET /api/public/observations" "$(api GET '/api/public/observations?limit=1')" 200
check "GET /api/public/metrics/daily" "$(api GET '/api/public/metrics/daily?limit=1')" 200
echo "GET /api/public/v2/observations (v4 read path, opt-in off): $(api GET '/api/public/v2/observations?limit=1')"
kx -n "$NS" exec deploy/"$V2"-worker -- wget -qO- "http://localhost:3030/api/health?failIfQueueConsumptionStuck=true&failIfEventPropagationStuck=true"; echo
exit $fail
