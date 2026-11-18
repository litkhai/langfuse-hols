#!/usr/bin/env bash
# 99 — delete the kind cluster and .work/ (results/ stays).
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
pkill -f "port-forward.*$KCTX" 2>/dev/null || true
kind delete cluster --name "$CLUSTER"
rm -rf "$WORK"
