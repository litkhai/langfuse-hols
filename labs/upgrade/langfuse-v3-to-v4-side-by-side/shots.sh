#!/usr/bin/env bash
# shots.sh <release> <name-prefix> — UI screenshots of one release (optional; needs Playwright:
# PLAYWRIGHT_DIR=<dir with node_modules/playwright>). Pages: the trace list, and one trace written
# by SDK v3 on v3 before the upgrade. Saved to results/<prefix>-*.png.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
rel=${1:?release}; prefix=${2:?prefix}
t=$(jq -r 'select(.phase=="v3-start" and (.producer|startswith("python-sdk"))) | .trace_id' "$WORK/sent.jsonl" | head -1)
url=$(pf shots "$rel"-langfuse-web 3000); trap 'pf_stop shots' EXIT
LF_USER=$LF_USER LF_PASSWORD=$LF_PASSWORD node shots.mjs "$url" "$RES" \
  "$prefix-traces=/project/$LF_PROJECT/traces" "$prefix-v3-trace=/project/$LF_PROJECT/traces/$t"
