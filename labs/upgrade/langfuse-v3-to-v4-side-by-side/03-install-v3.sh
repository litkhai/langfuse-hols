#!/usr/bin/env bash
# 03 — the running v3 deployment: chart 1.5.41, Langfuse 3.172.1, every store external.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh

log "helm install $V3 chart $CHART_V1, Langfuse $LF_V3"
t0=$(now); v3_install; echo "install: $(elapsed "$t0") s"
# The worker looks for background migrations once, at start; on a first install it starts before
# web has created the tables ("The table public.background_migrations does not exist", seen on
# the first run). Restart it after web is up.
kx -n "$NS" rollout restart deploy/"$V3"-langfuse-worker
kx -n "$NS" rollout status deploy/"$V3"-langfuse-worker --timeout=600s
kx -n "$NS" apply -f helpers.yaml
kx -n "$NS" rollout status deploy/mock-llm --timeout=300s
kx -n "$NS" wait --for=condition=Ready pod/lab-curl --timeout=300s
kx -n "$NS" get pods -o wide

log "what v3 built"
echo "ClickHouse schema version (default db): $(ch -q 'SELECT version FROM default.schema_migrations ORDER BY sequence DESC LIMIT 1')"
ch -q "SELECT name, engine FROM system.tables WHERE database = 'default' ORDER BY name FORMAT TSV"
echo "Prisma migrations applied: $(psql_ langfuse -c 'SELECT count(*) FROM _prisma_migrations WHERE finished_at IS NOT NULL')"
echo "last Prisma migration: $(psql_ langfuse -c 'SELECT migration_name FROM _prisma_migrations ORDER BY migration_name DESC LIMIT 1')"
psql_ langfuse -c "SELECT name, finished_at IS NOT NULL AS finished, failed_at IS NOT NULL AS failed FROM background_migrations ORDER BY name"

url=$(pf app langfuse-app 3000); trap 'pf_stop app' EXIT
curl -s "$url/api/public/health"; echo
