#!/usr/bin/env bash
# 99 — remove what this lab added: the Grafana container and the database lab_langfuse_ch_dashboard.
# The shared stack keeps running. The seeded traces, scores and prompts stay in Langfuse (environment
# lab-ch-dashboard, tag lab:langfuse-ch-dashboard); --traces also deletes the traces through the
# public API (Langfuse removes them from ClickHouse asynchronously).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
GRAFANA_ADMIN_PASSWORD=x lab_compose down -v
docker exec "$LF_PROJECT-clickhouse-1" clickhouse-client -u "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
  -q "DROP DATABASE IF EXISTS lab_langfuse_ch_dashboard SYNC"
echo "✓ Grafana removed, database lab_langfuse_ch_dashboard dropped"
if [[ "${1:-}" == "--traces" ]]; then
  (cd "$LAB_DIR" && "$PY" - <<'PY'
import sys
sys.path.insert(0, ".")
from lablib import ENVIRONMENT, PROJECT, api, ch
ids = [r["trace_id"] for r in ch(f"SELECT DISTINCT trace_id FROM default.events_core WHERE project_id = '{PROJECT}' "
                                 f"AND environment = '{ENVIRONMENT}' AND parent_span_id = ''")]
for i in range(0, len(ids), 500):
    api("DELETE", "/api/public/traces", json={"traceIds": ids[i:i + 500]}).raise_for_status()
print(f"✓ deletion requested for {len(ids)} traces")
PY
  )
fi
