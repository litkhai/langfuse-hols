#!/usr/bin/env bash
# 01 — kind cluster, the app Secret, and the two SDK virtualenvs.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh

log "tools"
helm version --short; kubectl version --client | head -1; kind version; jq --version
"$PYTHON" - <<'PY'
import sys; assert sys.version_info >= (3, 10), "Python 3.10+ (langfuse 3.15 / 4.x)"; print("python", sys.version.split()[0])
PY

if ! kind get clusters | grep -qx "$CLUSTER"; then
  log "kind cluster $CLUSTER"
  kind create cluster --name "$CLUSTER" --wait 120s
fi
kx get nodes -o wide

log "namespace and the shared app Secret (salt, encryption key, NextAuth secret)"
kx create namespace "$NS" --dry-run=client -o yaml | kx apply -f -
if ! kx -n "$NS" get secret langfuse >/dev/null 2>&1; then
  kx -n "$NS" create secret generic langfuse \
    --from-literal=salt="$(openssl rand -base64 32)" \
    --from-literal=encryption-key="$(openssl rand -hex 32)" \
    --from-literal=nextauth-secret="$(openssl rand -base64 32)"
fi
# Both releases read this Secret; neither Helm release owns it.
kx -n "$NS" get secret langfuse -o jsonpath='{.data}' | jq -r 'keys[]'

log "SDK virtualenvs: v3 (old producer) and v4 (v4-compatible producer)"
[ -x "$PY" ]  || { "$PYTHON" -m venv "$WORK/venv-v3"; "$WORK/venv-v3/bin/pip" -q install -r requirements-v3.txt; }
[ -x "$PY4" ] || { "$PYTHON" -m venv "$WORK/venv-v4"; "$WORK/venv-v4/bin/pip" -q install -r requirements-v4.txt; }
"$WORK/venv-v3/bin/pip" show langfuse | sed -n 2p
"$WORK/venv-v4/bin/pip" show langfuse | sed -n 2p
