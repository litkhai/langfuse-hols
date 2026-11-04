#!/usr/bin/env bash
# Comparison only: the same kong-model.yml on the Enterprise image (kong/kong-gateway, Gen AI
# spans from 3.13), started WITHOUT a licence. Sends one /raw call (no bridge) and prints the
# generation Kong itself emitted, as stored in events_full. Not part of 04-check.py.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$HERE/01-up.sh" --ee >/dev/null 2>&1
tid=$(curl -fsS -D - -o /dev/null http://localhost:18300/raw -H 'content-type: application/json' \
  -H 'x-user-id: user-1001' -d '{"messages":[{"role":"user","content":"hello through the enterprise image"}]}' \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="x-trace-id"{print $2}')
echo "ee /raw  trace $tid  ($(curl -fsS http://localhost:18301/ | python3 -c 'import json,sys; print("Kong", json.load(sys.stdin)["version"])'))"
for _ in $(seq 1 20); do
  out=$(docker exec langfuse-hols-v4-clickhouse-1 clickhouse-client -q "
    SELECT name, type, user_id, provided_model_name, usage_details, input, output,
           arrayFilter(x -> x LIKE 'attributes.gen_ai.%', metadata_names) AS gen_ai_attributes
    FROM events_full WHERE trace_id = '$tid' AND type = 'GENERATION' FORMAT Vertical" 2>/dev/null || true)
  [[ -n "$out" ]] && break
  sleep 3
done
echo "${out:-no generation arrived}"
LF_OTEL_AUTH=unused docker compose -f "$HERE/docker-compose.yml" --profile ee rm -sf kong-model-ee >/dev/null 2>&1
