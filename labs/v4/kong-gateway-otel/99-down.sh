#!/usr/bin/env bash
# Remove this lab's containers (project lf-kong-lab). The v4 Langfuse stack and the traces stay.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LF_OTEL_AUTH=unused docker compose -f "$HERE/docker-compose.yml" --profile ee down --remove-orphans
rm -rf "$HERE/.run"
