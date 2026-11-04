#!/usr/bin/env bash
# Start the mock model and two Kong OSS gateways (project lf-kong-lab), exporting to the v4 stack.
# Needs the v4 stack up (_base/bin/up.sh v4) — this script only reads its keys and never
# starts, stops or changes it.   Usage: ./01-up.sh [--ee]   (--ee also starts kong-model-ee)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../../_base/lib/env.sh" v4
load_env "${LF_ENV_FILE:-$BASE_DIR/.env}"   # LF_ENV_FILE: another clone's _base/.env
: "${LANGFUSE_INIT_PROJECT_PUBLIC_KEY:?missing in _base/.env (or LF_ENV_FILE)}" "${LANGFUSE_INIT_PROJECT_SECRET_KEY:?missing in _base/.env (or LF_ENV_FILE)}"

curl -fsS -o /dev/null http://localhost:3000/api/public/health \
  || { echo "Langfuse is not answering on :3000 — start it with _base/bin/up.sh v4" >&2; exit 1; }

LF_OTEL_AUTH="Basic $(printf '%s:%s' "$LANGFUSE_INIT_PROJECT_PUBLIC_KEY" "$LANGFUSE_INIT_PROJECT_SECRET_KEY" | base64 | tr -d '\n')"
export LF_OTEL_AUTH

profiles=()
[[ "${1:-}" == "--ee" ]] && profiles=(--profile ee)
docker compose -f "$HERE/docker-compose.yml" ${profiles[@]+"${profiles[@]}"} up -d

ports=(18001 18101); [[ "${1:-}" == "--ee" ]] && ports+=(18301)
for port in "${ports[@]}"; do
  for _ in $(seq 1 60); do
    curl -fsS -o /dev/null "http://localhost:$port/status" 2>/dev/null && break
    sleep 1
  done
  printf 'admin :%s  ' "$port"; curl -fsS "http://localhost:$port/" | python3 -c 'import json,sys; print("Kong", json.load(sys.stdin)["version"])'
done
