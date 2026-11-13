#!/usr/bin/env bash
# Stops the lab. --purge also deletes the volumes and .run/ (installed hook, test repositories, results).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [[ "${1:-}" == "--purge" ]]; then
  lab_compose down -v
  rm -rf "$RUN_DIR"
else
  lab_compose down
fi
