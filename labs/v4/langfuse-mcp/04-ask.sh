#!/usr/bin/env bash
# 04-ask.sh <id> <servers> <question> — ask Claude Code one question through MCP, non-interactively.
#
#   <servers>  clickhouse | langfuse | both — which servers of .mcp.json this run may use
#              (--strict-mcp-config: no other MCP server of the user's own configuration)
#   Runs `claude -p` in $CLIENT_DIR (lib.sh) with only the project's settings (--setting-sources
#   project: .claude/settings.json allows the read tools, denies Langfuse's write tools, Bash,
#   Edit, Write and the web; the user's own hooks and plugins are not loaded) and saves the
#   stream-json transcript as .run/ask/<id>.jsonl. 05-transcripts.py turns it into the SQL
#   and answer shown in the README.
#   CLAUDE_MODEL picks the model (default: sonnet). HINT=1 adds schema-hint.md to the system prompt.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
id="$1"; servers="$2"; question="$3"
mkdir -p "$RUN_DIR/ask"
export CLICKHOUSE_RO_PASSWORD="$(sed -n 's/^CLICKHOUSE_RO_PASSWORD=//p' "$RUN_DIR/ch-ro.env")"
export LANGFUSE_MCP_AUTH="$(printf '%s:%s' "$LANGFUSE_PUBLIC_KEY" "$LANGFUSE_SECRET_KEY" | base64 | tr -d '\n')"
export LANGFUSE_HOST="${LANGFUSE_HOST:-http://localhost:3000}"
python3 - "$LAB_DIR/.mcp.json" "$servers" > "$RUN_DIR/ask/mcp-$servers.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1])); want = sys.argv[2]
keep = ["clickhouse", "langfuse"] if want == "both" else [want]
print(json.dumps({"mcpServers": {k: v for k, v in cfg["mcpServers"].items() if k in keep}}, indent=2))
PY
client_dir
# HINT=1 appends schema-hint.md (where Langfuse v4 keeps its rows) to the system prompt.
hint=()
[[ "${HINT:-0}" == 1 ]] && hint=(--append-system-prompt-file "$LAB_DIR/schema-hint.md")
start=$(date +%s)
# A minimal environment: the signed-in Claude Code account (no ANTHROPIC_API_KEY that
# _base/.env may hold for other labs), no variables of a host that embeds Claude Code, no
# auto-memory of other sessions (also off in .claude/settings.json).
( cd "$CLIENT_DIR" && env -i HOME="$HOME" PATH="$PATH" USER="$USER" LANG="${LANG:-en_US.UTF-8}" \
    CLICKHOUSE_RO_PASSWORD="$CLICKHOUSE_RO_PASSWORD" LANGFUSE_MCP_AUTH="$LANGFUSE_MCP_AUTH" \
    LANGFUSE_HOST="$LANGFUSE_HOST" CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
  claude -p "$question" \
    --model "${CLAUDE_MODEL:-sonnet}" \
    --setting-sources project --permission-mode default \
    --mcp-config "$RUN_DIR/ask/mcp-$servers.json" --strict-mcp-config \
    --output-format stream-json --verbose \
    --no-session-persistence \
    ${hint[@]+"${hint[@]}"} \
    < /dev/null > "$RUN_DIR/ask/$id.jsonl" )
echo "✓ $id ($servers${HINT:+, hint=$HINT}): $(( $(date +%s) - start )) s → .run/ask/$id.jsonl"
