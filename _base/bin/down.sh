#!/usr/bin/env bash
# down.sh — stop the shared stack. Pass --purge to also delete all volumes (Postgres,
# ClickHouse, Redis, MinIO data) for a clean slate.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/env.sh"

# Include every overlay so lab-specific sidecars (e.g. the lab-08 masking
# service) and their config are torn down too. --remove-orphans is belt-and-braces.
COMPOSE=(lf_compose ee masking governance --)

if [[ "${1:-}" == "--purge" ]]; then
  echo "▶ Stopping stack and DELETING all data volumes…"
  # EE overlay needs the var to parse even on `down`; supply a dummy if unset.
  LANGFUSE_EE_LICENSE_KEY="${LANGFUSE_EE_LICENSE_KEY:-x}" "${COMPOSE[@]}" down -v --remove-orphans
  echo "✅ Stack down, volumes removed."
else
  echo "▶ Stopping stack (data volumes preserved). Use '--purge' to wipe data."
  LANGFUSE_EE_LICENSE_KEY="${LANGFUSE_EE_LICENSE_KEY:-x}" "${COMPOSE[@]}" down --remove-orphans
  echo "✅ Stack down. Volumes kept — '_base/bin/up.sh' will resume with your data."
fi
