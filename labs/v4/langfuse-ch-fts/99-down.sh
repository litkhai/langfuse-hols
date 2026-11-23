#!/usr/bin/env bash
# Removes the lab's own ClickHouse container and drops database lab_langfuse_ch_fts (the copy and its
# materialized view) on the shared stack's server. The seeded traces stay in Langfuse; --traces also
# deletes them through the public API (every trace tagged lab:langfuse-ch-fts). The shared stack
# itself is not touched: no down.sh, no truncation of Langfuse tables.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
docker rm -f "$FTS_CH" >/dev/null 2>&1 && echo "• removed container $FTS_CH" || echo "• no container $FTS_CH"
lf_ch "DROP DATABASE IF EXISTS $LAB_DB SYNC" && echo "• dropped $LAB_DB on the stack's ClickHouse"
if [[ "${1:-}" == "--traces" ]]; then
  python3 - <<'PY'
import base64, json, os, sys, urllib.request
sys.path.insert(0, os.environ["LAB_DIR"])
import lablib
ids = [r["trace_id"] for r in lablib.rows("LF", f"SELECT DISTINCT trace_id FROM default.events_full WHERE has(tags, '{lablib.LAB_TAG}')")]
auth = base64.b64encode(f"{os.environ['LANGFUSE_PUBLIC_KEY']}:{os.environ['LANGFUSE_SECRET_KEY']}".encode()).decode()
host = os.environ.get("LANGFUSE_HOST", "http://localhost:3000").rstrip("/")
for i in range(0, len(ids), 500):
    req = urllib.request.Request(f"{host}/api/public/traces", method="DELETE", data=json.dumps({"traceIds": ids[i:i + 500]}).encode(),
                                 headers={"Authorization": "Basic " + auth, "Content-Type": "application/json"})
    urllib.request.urlopen(req).read()
print(f"• deleted {len(ids)} traces tagged {lablib.LAB_TAG} (Langfuse removes them from ClickHouse in the background)")
PY
fi
