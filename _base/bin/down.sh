#!/usr/bin/env bash
# down.sh — stop the shared stack of one track. Pass --purge to also delete all volumes
# (Postgres, ClickHouse, Redis, MinIO data) for a clean slate.
#
#   _base/bin/down.sh <v3|v4> [--purge]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! "${1:-}" =~ ^v[0-9]+$ || ! -f "$here/${1:-}/versions.env" ]]; then
  echo "usage: _base/bin/down.sh <v3|v4> [--purge]" >&2
  exit 2
fi
. "$here/lib/env.sh" "$1"
shift

# Include every overlay so lab-specific sidecars (e.g. the lab-08 masking
# service) and their config are torn down too. --remove-orphans is belt-and-braces.
COMPOSE=(lf_compose ee masking governance --)

if [[ "${1:-}" == "--purge" ]]; then
  echo "▶ Stopping the ${TRACK} stack and DELETING all its data volumes…"
  # EE overlay needs the var to parse even on `down`; supply a dummy if unset.
  LANGFUSE_EE_LICENSE_KEY="${LANGFUSE_EE_LICENSE_KEY:-x}" "${COMPOSE[@]}" down -v --remove-orphans
  echo "✅ Stack ${TRACK} down, volumes removed."
else
  echo "▶ Stopping the ${TRACK} stack (data volumes preserved). Use '--purge' to wipe data."
  LANGFUSE_EE_LICENSE_KEY="${LANGFUSE_EE_LICENSE_KEY:-x}" "${COMPOSE[@]}" down --remove-orphans
  echo "✅ Stack ${TRACK} down. Volumes kept — '_base/bin/up.sh ${TRACK}' will resume with your data."
fi
