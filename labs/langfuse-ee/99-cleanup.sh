#!/usr/bin/env bash
# 99-cleanup.sh — stop the stack. Pass --purge to also delete all volumes (Postgres,
# ClickHouse, Redis, MinIO data) for a clean slate.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.ee.yml)

if [[ "${1:-}" == "--purge" ]]; then
  echo "▶ Stopping stack and DELETING all data volumes…"
  # EE overlay needs the var to parse even on `down`; supply a dummy if unset.
  LANGFUSE_EE_LICENSE_KEY="${LANGFUSE_EE_LICENSE_KEY:-x}" "${COMPOSE[@]}" down -v
  echo "✅ Stack down, volumes removed."
else
  echo "▶ Stopping stack (data volumes preserved). Use '--purge' to wipe data."
  LANGFUSE_EE_LICENSE_KEY="${LANGFUSE_EE_LICENSE_KEY:-x}" "${COMPOSE[@]}" down
  echo "✅ Stack down. Volumes kept — './01-up.sh' will resume with your data."
fi
