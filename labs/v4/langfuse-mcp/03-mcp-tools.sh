#!/usr/bin/env bash
# 03-mcp-tools.sh — what each MCP server offers, read from the running servers.
#
#   Langfuse:   POST $LANGFUSE_HOST/api/public/mcp  initialize + tools/list (Basic auth with the
#               project key). Writes .run/langfuse-tools.json, prints server info and the tool
#               count by readOnlyHint, and fails if a tool without readOnlyHint is missing from
#               the deny list of .claude/settings.json (a new write tool must be denied first).
#   Also: the same request without credentials must be refused (401).
#   ClickHouse: starts mcp-clickhouse 0.7.0 over stdio (uvx) as lab_mcp_ro and lists its tools.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mkdir -p "$RUN_DIR"
H="${LANGFUSE_HOST:-http://localhost:3000}"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lab-langfuse-mcp","version":"0"}}}'
LIST='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
hdr=(-H "Content-Type: application/json" -H "Accept: application/json, text/event-stream")

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$H/api/public/mcp" "${hdr[@]}" -d "$INIT")
[[ "$code" == 401 ]] && echo "✓ without credentials: HTTP $code" || { echo "✗ without credentials: HTTP $code (expected 401)"; exit 1; }

curl -s -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" -X POST "$H/api/public/mcp" "${hdr[@]}" -d "$INIT" > "$RUN_DIR/langfuse-init.json"
curl -s -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" -X POST "$H/api/public/mcp" "${hdr[@]}" -d "$LIST" > "$RUN_DIR/langfuse-tools.json"

python3 - "$RUN_DIR" "$LAB_DIR/.claude/settings.json" <<'PY'
import json, sys, collections
run, settings = sys.argv[1], sys.argv[2]
info = json.load(open(f"{run}/langfuse-init.json"))["result"]
tools = json.load(open(f"{run}/langfuse-tools.json"))["result"]["tools"]
print(f"✓ Langfuse MCP: serverInfo {info['serverInfo']}, protocol {info['protocolVersion']}")
ro = [t["name"] for t in tools if (t.get("annotations") or {}).get("readOnlyHint")]
rw = [t["name"] for t in tools if t["name"] not in ro]
destructive = [t["name"] for t in tools if (t.get("annotations") or {}).get("destructiveHint")]
print(f"  {len(tools)} tools: {len(ro)} readOnlyHint, {len(rw)} without it ({len(destructive)} destructiveHint)")
groups = collections.Counter()
for n in [t["name"] for t in tools]:
    for key in ("Prompt", "Observation", "Metric", "Score", "Dataset", "Dashboard", "Evaluat", "Annotation", "Comment", "Model", "Experiment", "Alert"):
        if key.lower() in n.lower():
            groups[key] += 1; break
    else:
        groups["other"] += 1
print("  by area:", ", ".join(f"{k} {v}" for k, v in groups.most_common()))
print("  trace/observation reads:", ", ".join(n for n in ro if "bservation" in n or "Metric" in n))
deny = set(json.load(open(settings))["permissions"]["deny"])
missing = [n for n in rw if f"mcp__langfuse__{n}" not in deny]
if missing:
    sys.exit(f"✗ write tools not denied in .claude/settings.json: {missing}")
print(f"✓ every tool without readOnlyHint ({len(rw)}) is in the deny list of .claude/settings.json")
PY

# ClickHouse MCP over stdio: initialize, initialized, tools/list (stdin stays open until both answers arrive)
PW="$(sed -n 's/^CLICKHOUSE_RO_PASSWORD=//p' "$RUN_DIR/ch-ro.env")"
CLICKHOUSE_HOST=localhost CLICKHOUSE_PORT=8123 CLICKHOUSE_SECURE=false CLICKHOUSE_USER="$RO_USER" \
CLICKHOUSE_PASSWORD="$PW" CLICKHOUSE_DATABASE=default python3 - "$RUN_DIR" <<'PY'
import json, subprocess, sys
run = sys.argv[1]
p = subprocess.Popen(["uvx", "--python", "3.12", "mcp-clickhouse==0.7.0"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=open(f"{run}/mcp-clickhouse.stderr", "w"), text=True)
def send(m): p.stdin.write(json.dumps(m) + "\n"); p.stdin.flush()
def recv(i):
    for line in p.stdout:
        m = json.loads(line)
        if m.get("id") == i: return m["result"]
send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "lab-langfuse-mcp", "version": "0"}}})
print("✓ ClickHouse MCP: serverInfo", recv(1)["serverInfo"])
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
for t in recv(2)["tools"]:
    print("  ", t["name"], "|", t["description"].strip().splitlines()[0][:100])
p.stdin.close(); p.wait(timeout=10)
PY
grep -h -i -E "readonly|read-only|grant|warn" "$RUN_DIR/mcp-clickhouse.stderr" | head -5 || true
