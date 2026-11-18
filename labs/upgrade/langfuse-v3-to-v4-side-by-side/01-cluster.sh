#!/usr/bin/env bash
# 01 — kind cluster, the shared app Secret, and the two SDK virtualenvs.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh

log "tools and machine"
helm version --short; kubectl version --client | head -1; kind version; jq --version
docker info --format 'Docker {{.ServerVersion}}, VM {{.NCPU}} CPUs, {{.MemTotal}} bytes'
"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 10); print("python", sys.version.split()[0])'

if ! kind get clusters | grep -qx "$CLUSTER"; then
  log "kind cluster $CLUSTER"
  kind create cluster --name "$CLUSTER" --wait 120s
fi
kx get nodes -o wide

log "namespace and the app Secret both releases read (salt, encryption key, NextAuth secret)"
kx create namespace "$NS" --dry-run=client -o yaml | kx apply -f -
if ! kx -n "$NS" get secret langfuse >/dev/null 2>&1; then
  kx -n "$NS" create secret generic langfuse \
    --from-literal=salt="$(openssl rand -base64 32)" \
    --from-literal=encryption-key="$(openssl rand -hex 32)" \
    --from-literal=nextauth-secret="$(openssl rand -base64 32)"
fi
kx -n "$NS" get secret langfuse -o jsonpath='{.data}' | jq -r 'keys[]'

log "SDK virtualenvs"
[ -x "$PY" ]  || { "$PYTHON" -m venv "$WORK/venv-v3"; "$WORK/venv-v3/bin/pip" -q install -r requirements-v3.txt; }
[ -x "$PY4" ] || { "$PYTHON" -m venv "$WORK/venv-v4"; "$WORK/venv-v4/bin/pip" -q install -r requirements-v4.txt; }
"$WORK/venv-v3/bin/pip" show langfuse | sed -n 2p
"$WORK/venv-v4/bin/pip" show langfuse | sed -n 2p
