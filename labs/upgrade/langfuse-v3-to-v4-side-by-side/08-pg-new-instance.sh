#!/usr/bin/env bash
# 08 — Postgres option (a): v4 on a new Postgres instance (17.12) restored from a dump of v3's
# database, then back to option (b). The backfill gate is off while v4 runs on (a): the restored
# database has the v4 backfill rows unfinished and would rewrite the same ClickHouse data again.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
grep -q 'image: postgres:'"$PG_NEW" pg-new.yaml || die "pg-new.yaml does not pin postgres:$PG_NEW"
kx -n "$NS" apply -f pg-new.yaml
kx -n "$NS" rollout status statefulset/pg-new --timeout=600s
# The image's first start initialises the cluster on a socket-only server and then restarts it;
# pg_isready can pass in between (the first try of this step failed there). Wait for a real query.
for _ in $(seq 1 60); do psql_new postgres -c "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
psql_new langfuse -c "SHOW server_version"

log "dump v3's database (pg-main) and restore it on the new instance (pg-new)"
t0=$(now)
psql_new postgres -c "DROP DATABASE IF EXISTS langfuse WITH (FORCE)" >/dev/null
psql_new postgres -c "CREATE DATABASE langfuse" >/dev/null
kx -n "$NS" exec pg-main-0 -- env PGPASSWORD="$PG_PW" pg_dump -U postgres -Fc langfuse \
  | kx -n "$NS" exec -i pg-new-0 -- env PGPASSWORD="$PG_PW" pg_restore -U postgres -d langfuse --no-owner
echo "dump | restore across instances: $(elapsed "$t0") s"

log "v4 -> option (a)"
v4env "DATABASE_URL=postgresql://postgres:$PG_PW@pg-new:5432/langfuse" "LANGFUSE_BACKGROUND_MIGRATION_V4_ENABLE_HISTORIC_BACKFILL=false"
t0=$(now); restart "$V4"; echo "v4 restart incl. $(psql_new langfuse -c "SELECT count(*) FROM _prisma_migrations WHERE migration_name > '20260423084654_add_datasets_remote_experiment_enabled_col'") Prisma migrations: $(elapsed "$t0") s"
psql_new langfuse -c "SELECT 'Prisma migrations ran in ' || round(extract(epoch FROM max(finished_at) - min(started_at))::numeric, 1) || ' s' FROM _prisma_migrations WHERE migration_name > '20260423084654_add_datasets_remote_experiment_enabled_col'"
url=$(pf v4 "$V4"-langfuse-web 3000); trap 'pf_stop v4' EXIT
check "v4 on (a): GET /api/public/projects with the v3 key" "$(api "$url" GET /api/public/projects)" 200
check "v4 on (a): GET /api/public/v2/prompts/support-system" "$(api "$url" GET /api/public/v2/prompts/support-system)" 200
t=$(jq -r 'select(.phase=="v3-start" and (.producer|startswith("python-sdk"))) | .trace_id' "$WORK/sent.jsonl" | head -1)
check "v4 on (a): observations of a v3 trace (ClickHouse unchanged)" "$(apij "$url" "/api/public/v2/observations?traceId=$t" | jq '.data | length')" 4
"$PY" ui.py login "$url" "$WORK/v4a.jar"
pf_stop v4

log "v4 -> back to option (b), backfill gate on again (its chain is finished there, nothing reruns)"
v4env "DATABASE_URL=postgresql://postgres:$PG_PW@pg-main:5432/langfuse_v4" "LANGFUSE_BACKGROUND_MIGRATION_V4_ENABLE_HISTORIC_BACKFILL=true"
t0=$(now); restart "$V4"; echo "v4 restart (no pending migrations): $(elapsed "$t0") s"
url=$(pf v4 "$V4"-langfuse-web 3000)
check "v4 on (b): GET /api/public/projects" "$(api "$url" GET /api/public/projects)" 200
kx -n "$NS" delete -f pg-new.yaml --wait=false >/dev/null
exit $fail
