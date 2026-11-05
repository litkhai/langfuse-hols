#!/usr/bin/env bash
# Step 15 — delete the kind cluster lf-gateway-helm (steps 13–14). `--purge` also removes the Helm
# secrets values and the lab CA in .run/. The compose project is not touched (99-down.sh).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kind delete cluster --name lf-gateway-helm
if [[ "${1:-}" == "--purge" ]]; then
  rm -f "$RUN_DIR/helm-secrets.yaml" "$RUN_DIR/state-helm.json"
  rm -rf "$RUN_DIR/helm-tls"
fi
