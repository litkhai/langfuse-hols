#!/usr/bin/env bash
# 02 — chart v1 (Bitnami stores) with an old Langfuse v3: the starting point.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh

log "helm install $V1 chart $CHART_V1, Langfuse $LF_START"
hx upgrade --install "$V1" "$CHART" --version "$CHART_V1" -n "$NS" -f v1-values.yaml \
  --set langfuse.image.tag="$LF_START" --wait --timeout 15m

kx -n "$NS" get pods -o wide
log "store versions"
kx -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
v1_ch -q "SELECT version()"
v1_psql -c "SHOW server_version"
v1_psql -c "SHOW wal_level"
