#!/usr/bin/env bash
# 02-install.sh — install the langfuse 2.2.1 chart with values-base.yaml and the kind overlay.
#
# A FIRST install is staged; the same three steps apply on AKS, EKS and GKE:
#   1. data stores only (web and worker at 0): wait until KeeperCluster and ClickHouseCluster are Ready
#   2. one web pod: it runs the ClickHouse migrations against a cluster that is already up
#   3. the full values (web and worker HPAs, minimum 2)
# Why: on 2026-11-03 two first installs ended with "Dirty database version 5" and web restarting forever.
# The kubelet killed web mid-migration (liveness probe, chart default 20 s + 3 × 10 s; values-base.yaml now
# waits 300 s). Staging keeps the migrations off a ClickHouse that still restarts waiting for Keeper, and
# to one pod. Later upgrades run in one step.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="kubectl --context kind-langfuse-k8s -n langfuse"
H=(helm --kube-context kind-langfuse-k8s upgrade --install langfuse langfuse/langfuse --version 2.2.1 -n langfuse
   -f "$HERE/values-base.yaml" -f "$HERE/values-kind.yaml" --timeout 15m)
helm repo add langfuse https://langfuse.github.io/langfuse-k8s >/dev/null 2>&1 || true
helm repo update langfuse >/dev/null
# With HPA off the chart uses web.replicas, falling back to langfuse.replicas; clearing the per-deployment
# value lets langfuse.replicas set both.
scaled() {  # scaled <n> → overrides for n web and n worker pods, HPA off
  echo --set langfuse.replicas="$1" --set langfuse.web.replicas=null --set langfuse.worker.replicas=null \
       --set langfuse.web.hpa.enabled=false --set langfuse.worker.hpa.enabled=false
}

if ! helm --kube-context kind-langfuse-k8s status langfuse -n langfuse >/dev/null 2>&1; then
  echo "════ first install, step 1/3: ClickHouse and Keeper only ════"
  "${H[@]}" $(scaled 0) >/dev/null
  $K wait --for=condition=Ready keepercluster/langfuse --timeout=15m >/dev/null
  $K wait --for=condition=Ready clickhousecluster/langfuse --timeout=15m >/dev/null
  echo "  KeeperCluster and ClickHouseCluster Ready"
  echo "════ first install, step 2/3: one web pod runs the migrations ════"
  "${H[@]}" $(scaled 1) >/dev/null
  $K rollout status deploy/langfuse-web --timeout=15m >/dev/null
  echo "  web ready (migrations applied)"
  echo "════ first install, step 3/3: full values ════"
else
  echo "════ helm upgrade (release exists) ════"
fi
"${H[@]}" >/dev/null
$K wait --for=condition=Ready keepercluster/langfuse --timeout=15m >/dev/null
$K wait --for=condition=Ready clickhousecluster/langfuse --timeout=15m >/dev/null
$K rollout status deploy/langfuse-web deploy/langfuse-worker --timeout=15m >/dev/null
$K get pods -o custom-columns='  POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' --no-headers
echo
echo "✅ installed. Next: ./03-checks.sh"
