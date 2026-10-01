#!/usr/bin/env bash
# up.sh — bring the shared Langfuse self-hosted stack up (OSS mode) and wait until ready.
#
#   _base/bin/up.sh           # OSS stack (labs 01–04, langfuse-eval)
#   EE=1 _base/bin/up.sh      # same stack + enterprise overlay (labs 05–11; needs license key)
#                             # (labs 08 & 10 add their own overlays via their scripts)
#
# Works from any directory: compose files and `.env` resolve against `_base/`.
# Image versions: LANGFUSE_VERSION / CLICKHOUSE_VERSION / REDIS_VERSION /
# POSTGRES_VERSION (see _base/.env.example); unset = the compose defaults.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/env.sh"

if [[ ! -f "$BASE_DIR/.env" ]]; then
  echo "▶ No _base/.env found — creating one from _base/.env.example (edit the # CHANGEME values for prod)."
  cp "$BASE_DIR/.env.example" "$BASE_DIR/.env"
  chmod 600 "$BASE_DIR/.env"
fi

OVERLAYS=()
MODE="OSS"
if [[ "${EE:-0}" == "1" ]]; then
  OVERLAYS+=(ee)
  MODE="ENTERPRISE"
fi

echo "▶ Starting Langfuse stack in ${MODE} mode (postgres · clickhouse · redis · minio · web · worker)…"
lf_compose ${OVERLAYS[@]+"${OVERLAYS[@]}"} -- up -d

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
    echo; echo "⚠ Timed out. Check logs:  docker logs -f langfuse-hols-langfuse-web-1"
    exit 1
  fi
done

# Load the headless-init creds for the printout (best effort)
load_env "$BASE_DIR/.env"

cat <<EOT

────────────────────────────────────────────────────────────
  Langfuse UI      ${HOST}
  Login            ${LANGFUSE_INIT_USER_EMAIL:-admin@example.com} / ${LANGFUSE_INIT_USER_PASSWORD:-(see _base/.env)}
  Project          ${LANGFUSE_INIT_PROJECT_NAME:-LLM Observability}
  API public key   ${LANGFUSE_INIT_PROJECT_PUBLIC_KEY:-pk-lf-workshop-public}

  MinIO console    http://localhost:9091   (${MINIO_ROOT_USER:-minio} / ${MINIO_ROOT_PASSWORD:-miniosecret})
  ClickHouse HTTP  http://localhost:8123   (${CLICKHOUSE_USER:-clickhouse} / ${CLICKHOUSE_PASSWORD:-clickhouse})

  Next (from the repository root):
    _base/bin/check.sh                      # readiness: containers, migrations, keys
    python3.12 -m venv .venv && source .venv/bin/activate     # Python 3.10+
    pip install -r _base/requirements.txt
    python _base/bin/seed_traces.py         # or labs/langfuse-ee/02-generate-traces.py
────────────────────────────────────────────────────────────
EOT
