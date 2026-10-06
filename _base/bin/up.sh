#!/usr/bin/env bash
# up.sh — bring the shared Langfuse self-hosted stack up (OSS mode) and wait until ready.
#
#   _base/bin/up.sh <v3|v4>           # OSS stack of that track (labs 01–04, langfuse-eval)
#   EE=1 _base/bin/up.sh <v3|v4>      # same stack + enterprise overlay (labs 05–11; needs license key)
#                                     # (labs 08 & 10 add their own overlays via their scripts)
#
# The track is required: it selects the image pins in _base/<track>/versions.env and the
# compose project (langfuse-hols-<track>). Both tracks publish the same host ports, so
# only one runs at a time — this script refuses to start while the other one is up.
#
# Works from any directory: compose files and `.env` resolve against `_base/`.
# Image versions: the track's versions.env sets LANGFUSE_VERSION / CLICKHOUSE_VERSION;
# a value in _base/.env or in the shell wins (see _base/.env.example). REDIS_VERSION /
# POSTGRES_VERSION unset = the compose defaults.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! "${1:-}" =~ ^v[0-9]+$ || ! -f "$here/${1:-}/versions.env" ]]; then
  echo "usage: _base/bin/up.sh <v3|v4>     (EE=1 _base/bin/up.sh <v3|v4> adds the enterprise overlay)" >&2
  exit 2
fi
. "$here/lib/env.sh" "$1"

# The other track's stack uses the same host ports (3000, 3030, 5432, 6379, 8123, 9000,
# 9090, 9091): starting this one on top of it would fail half-way. Refuse up front.
for f in "$BASE_DIR"/v[0-9]*/versions.env; do
  other="$(basename "$(dirname "$f")")"
  [[ "$other" == "$TRACK" ]] && continue
  if [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=langfuse-hols-$other")" ]]; then
    echo "✗ the $other track is running and uses the same host ports — stop it first: _base/bin/down.sh $other" >&2
    exit 1
  fi
done

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

echo "▶ Starting Langfuse ${TRACK} stack in ${MODE} mode (postgres · clickhouse · redis · minio · web · worker)…"
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
    echo; echo "⚠ Timed out. Check logs:  docker logs -f ${LF_PROJECT}-langfuse-web-1"
    exit 1
  fi
done

# Load the headless-init creds for the printout (best effort)
load_env "$BASE_DIR/.env"

cat <<EOT

────────────────────────────────────────────────────────────
  Langfuse UI      ${HOST}   (track ${TRACK})
  Login            ${LANGFUSE_INIT_USER_EMAIL:-admin@example.com} / ${LANGFUSE_INIT_USER_PASSWORD:-(see _base/.env)}
  Project          ${LANGFUSE_INIT_PROJECT_NAME:-LLM Observability}
  API public key   ${LANGFUSE_INIT_PROJECT_PUBLIC_KEY:-pk-lf-workshop-public}

  MinIO console    http://localhost:9091   (${MINIO_ROOT_USER:-minio} / ${MINIO_ROOT_PASSWORD:-miniosecret})
  ClickHouse HTTP  http://localhost:8123   (${CLICKHOUSE_USER:-clickhouse} / ${CLICKHOUSE_PASSWORD:-clickhouse})

  Next (from the repository root):
    _base/bin/check.sh ${TRACK}                  # readiness: containers, migrations, keys
    python3.12 -m venv .venv-${TRACK} && source .venv-${TRACK}/bin/activate     # Python 3.10+
    pip install -r _base/${TRACK}/requirements.txt
    python _base/${TRACK}/seed_traces.py         # or the lab's own seed script
────────────────────────────────────────────────────────────
EOT
