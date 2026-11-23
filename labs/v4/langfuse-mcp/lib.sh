# lib.sh — sourced by this lab's shell scripts. Not executed.
#
#   LAB_DIR      this directory
#   RUN_DIR      $LAB_DIR/.run (gitignored): generated passwords, the rendered users.d file, results
#   CH_CONTAINER the shared stack's ClickHouse container (langfuse-hols-v4-clickhouse-1)
#   ch_admin     clickhouse-client inside that container as the stack's admin user ($CLICKHOUSE_USER)
#   ch_ro        clickhouse-client inside that container as lab_mcp_ro (the MCP user)
#   CLIENT_DIR   /tmp/lab-langfuse-mcp-client: where Claude Code runs (04, 07). Outside the
#                repository, so no CLAUDE.md of the repository is loaded; holds a copy of
#                .claude/settings.json (client_dir prepares it)
#
# The lab runs on the shared v4 stack (`_base/bin/up.sh v4`). The secrets file defaults to
# _base/.env of this clone; LF_ENV_FILE points at another clone's (e.g. when the stack was
# started from a different checkout).
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$LAB_DIR/../../../_base/lib/env.sh" v4
RUN_DIR="$LAB_DIR/.run"
LF_ENV_FILE="${LF_ENV_FILE:-$BASE_DIR/.env}"
export LF_ENV_FILE
load_env "$LF_ENV_FILE"
CH_CONTAINER="$LF_PROJECT-clickhouse-1"
RO_USER=lab_mcp_ro
LAB_DB=lab_langfuse_mcp

ch_admin() {
  docker exec -i "$CH_CONTAINER" clickhouse-client -u "${CLICKHOUSE_USER:-clickhouse}" --password "${CLICKHOUSE_PASSWORD:-clickhouse}" "$@"
}

ch_ro() {
  [[ -f "$RUN_DIR/ch-ro.env" ]] || { echo "✗ $RUN_DIR/ch-ro.env missing: run 01-ro-user.sh" >&2; return 1; }
  local pw; pw="$(sed -n 's/^CLICKHOUSE_RO_PASSWORD=//p' "$RUN_DIR/ch-ro.env")"
  docker exec -i "$CH_CONTAINER" clickhouse-client -u "$RO_USER" --password "$pw" "$@"
}

CLIENT_DIR=/tmp/lab-langfuse-mcp-client
client_dir() {
  mkdir -p "$CLIENT_DIR/.claude"
  cp "$LAB_DIR/.claude/settings.json" "$CLIENT_DIR/.claude/settings.json"
}
