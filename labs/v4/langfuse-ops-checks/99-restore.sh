#!/usr/bin/env bash
# 99-restore.sh — back to the normal OSS v4 stack after an interrupted test: removes the second worker (02) and
# the A/B instances (04), recreates web + worker from the base compose file only, removes a leftover
# 05-audit-log LANGFUSE_VERSION override from _base/.env and the throwaway project langfuse-hols-v4audit.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ENVF="${LF_ENV_FILE:-$BASE_DIR/.env}"
sed -i.bak '/^LANGFUSE_VERSION=.*# 05-audit-log override$/d' "$ENVF" && rm -f "$ENVF.bak"
for c in $(docker ps -aq --filter label=com.docker.compose.project=langfuse-hols-v4audit); do docker rm -f "$c" >/dev/null; done
for v in $(docker volume ls -q --filter label=com.docker.compose.project=langfuse-hols-v4audit); do docker volume rm "$v" >/dev/null; done
for c in langfuse-worker-2 lf-a-web lf-a-worker lf-b-web lf-b-worker; do docker rm -f "$LF_PROJECT-$c-1" >/dev/null 2>&1 || true; done
docker exec -u 0 "$LF_PROJECT-clickhouse-1" rm -f /etc/clickhouse-server/users.d/zz-dbsep.xml 2>/dev/null || true
"$BASE_DIR/bin/up.sh" v4 >/dev/null
ops_restore
"$BASE_DIR/bin/check.sh" v4 | tail -2
