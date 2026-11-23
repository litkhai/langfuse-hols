#!/usr/bin/env bash
# 99-cleanup.sh — remove what this lab added to the shared v4 stack. Never touches Langfuse's
# own tables or other labs' objects.
#   always:    the side web container lab-langfuse-mcp-web (06), the Viewer key(s) it created
#              (UI, 99-delete-viewer-key.mjs; needs PLAYWRIGHT), the users.d file of lab_mcp_ro,
#              database lab_langfuse_mcp, /tmp/lab-langfuse-mcp-client
#   --traces:  also this lab's traces (Langfuse DELETE /api/public/traces, tag lab:langfuse-mcp)
#              and the prompt lab-langfuse-mcp-answer (DELETE /api/public/v2/prompts/<name>)
#   --purge:   also .run/
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
H="${LANGFUSE_HOST:-http://localhost:3000}"
docker rm -f lab-langfuse-mcp-web >/dev/null 2>&1 && echo "✓ side web container removed" || true
if [[ -n "${PLAYWRIGHT:-}" ]]; then PLAYWRIGHT="$PLAYWRIGHT" node "$LAB_DIR/99-delete-viewer-key.mjs"
else echo "· PLAYWRIGHT not set: delete the key \"lab-langfuse-mcp viewer\" in Project Settings → API Keys"; fi
rm -f "$RUN_DIR/viewer-key.env"
docker exec "$CH_CONTAINER" rm -f /etc/clickhouse-server/users.d/lab_mcp_ro.xml
for i in $(seq 1 30); do
  [[ "$(ch_admin -q "SELECT count() FROM system.users WHERE name='$RO_USER'" </dev/null)" == 0 ]] && break; sleep 1
done
echo "✓ $RO_USER removed (users left with that name: $(ch_admin -q "SELECT count() FROM system.users WHERE name='$RO_USER'" </dev/null))"
ch_admin -q "DROP DATABASE IF EXISTS $LAB_DB" </dev/null && echo "✓ database $LAB_DB dropped"
rm -rf "$CLIENT_DIR"
if [[ " $* " == *" --traces "* ]]; then
  ids=$(ch_admin -q "SELECT DISTINCT trace_id FROM default.events_full WHERE has(tags, 'lab:langfuse-mcp') FORMAT JSONCompactColumns" </dev/null \
        | python3 -c 'import json,sys; c=json.load(sys.stdin); print(json.dumps({"traceIds": c[0] if c else []}))')
  curl -fs -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" -X DELETE "$H/api/public/traces" -H "Content-Type: application/json" -d "$ids" >/dev/null \
    && echo "✓ deletion of $(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["traceIds"]))' "$ids") traces queued"
  curl -fs -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" -X DELETE "$H/api/public/v2/prompts/lab-langfuse-mcp-answer" >/dev/null \
    && echo "✓ prompt lab-langfuse-mcp-answer deleted" || echo "· prompt not deleted (absent?)"
  rm -f "$RUN_DIR/seed.json"
fi
[[ " $* " == *" --purge "* ]] && rm -rf "$RUN_DIR" && echo "✓ .run/ removed"
exit 0
