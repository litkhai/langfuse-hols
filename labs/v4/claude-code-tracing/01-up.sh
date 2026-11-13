#!/usr/bin/env bash
# Starts Langfuse v4 (the track pin) as compose project lf-cc-lab and waits for web.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ -f "$LF_ENV_FILE" ]] || { echo "✗ $LF_ENV_FILE missing: cp _base/.env.example _base/.env" >&2; exit 1; }
lab_compose up -d
wait_web
echo "✓ Langfuse $(curl -fsS http://localhost:13000/api/public/health) on http://localhost:13000"
