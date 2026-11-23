#!/usr/bin/env bash
# 06-viewer-key.sh — can the Langfuse MCP server be given a read-only key?
#
# Langfuse 4.56.0 has API-key roles (Admin, Viewer, Ingestion, Scores ingestion) behind two
# variables that default off: API_AUTH_MIGRATION=enforce and API_KEY_PROJECT_ROLES_ENABLE=true
# (web/src/env.mjs, .env.prod.example of v4.56.0). The shared stack runs without them, and the
# other labs on it must not be restarted, so this step starts a SECOND web container of the
# same image on 127.0.0.1:48300 against the same Postgres / ClickHouse / Redis / MinIO, with
# both variables set and with migrations and LANGFUSE_INIT_* off (it writes no schema and no
# init rows). Then:
#   1. 06-viewer-key.mjs creates a Viewer project key in its UI (captures/06-key-role.png)
#   2. 06-viewer-probe.py calls MCP with that key on :48300 (enforce) and on :3000 (legacy):
#      tools/list, getObservation with input, createScore on a lab trace
#   3. any score the probe managed to write is deleted with the admin key
# The side container stays up for 99-cleanup.sh, which also deletes the Viewer key.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mkdir -p "$RUN_DIR"
PLAYWRIGHT="${PLAYWRIGHT:-playwright}"
LF_IMAGE="langfuse/langfuse:$(sed -n 's/^LANGFUSE_VERSION=//p' "$TRACK_DIR/versions.env")"
if ! docker ps --format '{{.Names}}' | grep -qx lab-langfuse-mcp-web; then
  ( umask 077
    docker inspect "$LF_PROJECT-langfuse-web-1" --format '{{range .Config.Env}}{{println .}}{{end}}' \
      | grep -v -E '^(LANGFUSE_INIT_|NEXTAUTH_URL=|PATH=|container=|PORT=|BUILD_ID=|NODE_ENV=|DOCKER_BUILD=|NEXT_|$)' > "$RUN_DIR/web-roles.env"
    printf '%s\n' NEXTAUTH_URL=http://localhost:48300 LANGFUSE_AUTO_POSTGRES_MIGRATION_DISABLED=true \
      LANGFUSE_AUTO_CLICKHOUSE_MIGRATION_DISABLED=true API_AUTH_MIGRATION=enforce \
      API_KEY_PROJECT_ROLES_ENABLE=true >> "$RUN_DIR/web-roles.env" )
  docker rm -f lab-langfuse-mcp-web >/dev/null 2>&1 || true
  docker run -d --name lab-langfuse-mcp-web --network "${LF_PROJECT}_default" --memory 1500m \
    -p 127.0.0.1:48300:3000 --env-file "$RUN_DIR/web-roles.env" "$LF_IMAGE" >/dev/null
fi
for i in $(seq 1 60); do curl -fs -o /dev/null http://localhost:48300/api/public/health && break; sleep 3; done
curl -fs -o /dev/null http://localhost:48300/api/public/health || { echo "✗ side web not healthy"; exit 1; }
echo "✓ side web $LF_IMAGE on :48300 (API_AUTH_MIGRATION=enforce, API_KEY_PROJECT_ROLES_ENABLE=true)"

[[ -f "$RUN_DIR/viewer-key.env" ]] || PLAYWRIGHT="$PLAYWRIGHT" node "$LAB_DIR/06-viewer-key.mjs"
read -r TR OB < <(ch_admin -q "SELECT trace_id, span_id FROM default.events_full WHERE has(tags,'lab:langfuse-mcp') AND name='support-chat' AND positionUTF8(input, '010-0000-1234') > 0 LIMIT 1" </dev/null)
: > "$RUN_DIR/probe-scores.txt"
python3 "$LAB_DIR/06-viewer-probe.py" "$TR" "$OB"
while read -r sid; do
  [[ -n "$sid" ]] || continue
  curl -fs -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" -X DELETE "${LANGFUSE_HOST:-http://localhost:3000}/api/public/scores/$sid" >/dev/null \
    && echo "  probe score $sid deleted"
done < "$RUN_DIR/probe-scores.txt"
