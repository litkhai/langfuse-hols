#!/usr/bin/env bash
# Scenario A — a client calls the model gateway directly, with the header contract.
#   /raw   what Kong OSS exports on its own (spans only)
#   /chat  with the bridge: a generation (model, usage, input/output) and user/session/metadata
# Kong creates the trace (no incoming traceparent) and returns its ID in x-trace-id.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HERE/.run"; : > "$HERE/.run/traces.env"
RUN="run-$(date +%s)"
for route in raw chat; do
  tid=$(curl -fsS -D - -o "$HERE/.run/$route.json" "http://localhost:18000/$route" \
    -H 'content-type: application/json' \
    -H 'x-user-id: user-1001' -H "x-session-id: $RUN-direct" -H 'x-agent-id: none' -H 'x-project-id: demo-project' \
    -d "{\"messages\":[{\"role\":\"user\",\"content\":\"hello through /$route\"}]}" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-trace-id"{print $2}')
  echo "/$route  trace $tid  answer: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["choices"][0]["message"]["content"])' "$HERE/.run/$route.json")"
  echo "$(echo "$route" | tr a-z A-Z)_TRACE=$tid" >> "$HERE/.run/traces.env"
done
echo "RUN=$RUN" >> "$HERE/.run/traces.env"
