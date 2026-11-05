#!/usr/bin/env bash
# Stop this lab's containers (project lf-gateway-lab). Volumes stay unless --purge is given;
# --purge also deletes .run/ (gateway secrets, issued keys, run results).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
GW_SERVICE_KEY=x GW_JWT_PRIVATE_KEY=x   # only needed for interpolation
export GW_SERVICE_KEY GW_JWT_PRIVATE_KEY
if [[ "${1:-}" == "--purge" ]]; then
  lab_compose down -v
  rm -rf "$RUN_DIR"
else
  lab_compose down
fi
