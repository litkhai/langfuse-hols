#!/usr/bin/env bash
# 02 — the external data layer at the versions chart 1.5.41 bundles: ClickHouse 25.2 (one-replica
# cluster with Keeper), Postgres 17.3, Valkey 8.0.2, MinIO 2024.12.18.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh

export CH_START PG_MAIN VALKEY MINIO_IMAGE CH_PW PG_PW REDIS_PW S3_USER S3_PW BUCKET
python3 - data-layer.yaml >"$WORK/data-layer.yaml" <<'PY'
import os, re, sys
print(re.sub(r"\$\{(\w+)\}", lambda m: os.environ[m.group(1)], open(sys.argv[1]).read()), end="")
PY
kx -n "$NS" apply -f "$WORK/data-layer.yaml"
for s in clickhouse pg-main valkey; do kx -n "$NS" rollout status statefulset/$s --timeout=600s; done
kx -n "$NS" rollout status deploy/minio --timeout=600s

log "versions"
ch -q "SELECT version()"
ch -q "SELECT cluster, host_name, is_local FROM system.clusters WHERE cluster = 'default'"
ch -q "SELECT count() FROM system.zookeeper WHERE path = '/'" | sed 's/^/keeper root nodes: /'
psql_ langfuse -c "SHOW server_version"
rcli INFO server | grep -E '^(valkey_version|redis_version)'
kx -n "$NS" exec deploy/minio -- mc --version | head -1
