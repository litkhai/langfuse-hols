#!/usr/bin/env bash
# 02-install.sh — install the langfuse 2.2.1 chart with values-aks.yaml and the kind overlay, and wait.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="kubectl --context kind-langfuse-aks -n langfuse"
helm repo add langfuse https://langfuse.github.io/langfuse-k8s >/dev/null 2>&1 || true
helm repo update langfuse >/dev/null

echo "════ helm upgrade --install langfuse (chart 2.2.1) ════"
helm --kube-context kind-langfuse-aks upgrade --install langfuse langfuse/langfuse --version 2.2.1 -n langfuse \
  -f "$HERE/values-aks.yaml" -f "$HERE/values-kind.yaml" --timeout 15m >/dev/null
echo "  waiting for ClickHouse, Keeper, web and worker (first start runs the migrations)…"
# On a first start ClickHouse restarts a few times until Keeper is up (Coordination error, exit 231),
# and web until ClickHouse answers; both settle by themselves.
$K wait --for=condition=Ready keepercluster/langfuse --timeout=15m >/dev/null
$K wait --for=condition=Ready clickhousecluster/langfuse --timeout=15m >/dev/null
$K rollout status deploy/langfuse-web deploy/langfuse-worker --timeout=15m >/dev/null
$K get pods -o custom-columns='  POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' --no-headers
echo
echo "✅ installed. Next: ./03-checks.sh"
