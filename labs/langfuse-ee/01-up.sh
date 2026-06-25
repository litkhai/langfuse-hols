#!/usr/bin/env bash
# 01-up.sh — bring the Langfuse self-hosted stack up (OSS mode) and wait until ready.
#
#   ./01-up.sh           # OSS stack (labs 01–04)
#   EE=1 ./01-up.sh      # same stack + enterprise overlay (labs 05–07; needs license key)
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "▶ No .env found — creating one from .env.example (edit the # CHANGEME values for prod)."
  cp .env.example .env
fi

COMPOSE=(docker compose -f docker-compose.yml)
MODE="OSS"
if [[ "${EE:-0}" == "1" ]]; then
  COMPOSE+=(-f docker-compose.ee.yml)
  MODE="ENTERPRISE"
fi

echo "▶ Starting Langfuse stack in ${MODE} mode (postgres · clickhouse · redis · minio · web · worker)…"
"${COMPOSE[@]}" up -d

echo "▶ Waiting for langfuse-web to become healthy (first boot runs DB + ClickHouse migrations, ~2-3 min)…"
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
for i in $(seq 1 90); do
  if curl -fsS "${HOST}/api/public/health" >/dev/null 2>&1; then
    echo "✅ Langfuse is up after ~$((i*5))s."
    break
  fi
  printf '.'
  sleep 5
  if [[ $i -eq 90 ]]; then
    echo; echo "⚠ Timed out. Check logs:  docker compose logs -f langfuse-web"
    exit 1
  fi
done

# Load the headless-init creds for the printout (best effort)
. "$(dirname "$0")/_env.sh"; load_env

cat <<EOF

────────────────────────────────────────────────────────────
  Langfuse UI      ${HOST}
  Login            ${LANGFUSE_INIT_USER_EMAIL:-admin@example.com} / ${LANGFUSE_INIT_USER_PASSWORD:-(see .env)}
  Project          ${LANGFUSE_INIT_PROJECT_NAME:-LLM Observability}
  API public key   ${LANGFUSE_INIT_PROJECT_PUBLIC_KEY:-pk-lf-workshop-public}

  MinIO console    http://localhost:9091   (${MINIO_ROOT_USER:-minio} / ${MINIO_ROOT_PASSWORD:-miniosecret})
  ClickHouse HTTP  http://localhost:8123   (${CLICKHOUSE_USER:-clickhouse} / ${CLICKHOUSE_PASSWORD:-clickhouse})

  Next:
    python -m venv .venv && source .venv/bin/activate
    pip install "langfuse>=3" openai
    python 02-generate-traces.py
────────────────────────────────────────────────────────────
EOF
