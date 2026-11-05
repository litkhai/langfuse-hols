#!/usr/bin/env bash
# Step 13 — the AI Gateway through the official Helm chart on a local kind cluster (#91).
#
#   labs/v4/ai-gateway/13-helm-up.sh        # ~10 minutes the first time (images); LF_ENV_FILE as elsewhere
#
# Cluster lf-gateway-helm (one node, helm/kind-config.yaml). cert-manager v1.20.2 and
# clickhouse-operator 0.0.8 (the chart's ClickHouse runs on the operator; same pins as
# labs/v4/langfuse-k8s), Traefik 42.3.0 as the TLS front on 127.0.0.1:18443, a self-signed CA with
# certificates for langfuse.127.0.0.1.nip.io and gateway.127.0.0.1.nip.io, then the langfuse chart 2.2.3
# (Langfuse 4.75.0) with the gateway enabled and 2 gateway replicas. Secrets are generated once into
# .run/ (mode 600). The headless-init user and project keys come from the secrets file, so
# 02-setup.py works against this instance too (14-helm-check.py runs it).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env "$LF_ENV_FILE"
for c in kind kubectl helm openssl; do command -v "$c" >/dev/null || { echo "✗ please install $c" >&2; exit 1; }; done
CTX=kind-lf-gateway-helm
K=(kubectl --context "$CTX"); H=(helm --kube-context "$CTX")
HD="$LAB_DIR/helm"; TLS="$RUN_DIR/helm-tls"
mkdir -p "$RUN_DIR" && chmod 700 "$RUN_DIR"

echo "════ 1. kind cluster lf-gateway-helm ════"
kind get clusters 2>/dev/null | grep -qx lf-gateway-helm || kind create cluster --config "$HD/kind-config.yaml" --wait 120s

echo "════ 2. cert-manager v1.20.2, clickhouse-operator 0.0.8, Traefik 42.3.0 ════"
"${H[@]}" upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.20.2 \
  -n cert-manager --create-namespace --set crds.enabled=true --wait >/dev/null
"${H[@]}" upgrade --install clickhouse-operator oci://ghcr.io/clickhouse/clickhouse-operator-helm --version 0.0.8 \
  -n clickhouse-operator --create-namespace --wait >/dev/null
"${K[@]}" wait --for=condition=Established crd/clickhouseclusters.clickhouse.com crd/keeperclusters.clickhouse.com --timeout=120s >/dev/null
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo add langfuse https://langfuse.github.io/langfuse-k8s >/dev/null 2>&1 || true
helm repo update traefik langfuse >/dev/null
"${H[@]}" upgrade --install traefik traefik/traefik --version 42.3.0 -n traefik --create-namespace \
  -f "$HD/traefik-values.yaml" --wait >/dev/null
echo "  ready"

echo "════ 3. Self-signed CA and certificates ════"
if [[ ! -s "$TLS/ca.pem" ]]; then
  ( umask 077; mkdir -p "$TLS"; cd "$TLS"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=lf-gateway-helm lab CA" \
      -keyout ca.key -out ca.pem 2>/dev/null
    for h in langfuse gateway; do
      openssl req -newkey rsa:2048 -nodes -subj "/CN=$h.127.0.0.1.nip.io" -keyout "$h.key" -out "$h.csr" 2>/dev/null
      printf 'subjectAltName=DNS:%s.127.0.0.1.nip.io\nextendedKeyUsage=serverAuth\n' "$h" > "$h.ext"
      openssl x509 -req -in "$h.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -extfile "$h.ext" -out "$h.pem" 2>/dev/null
    done )
fi
"${K[@]}" create namespace langfuse --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
for pair in "lf-web-tls langfuse" "lf-gateway-tls gateway"; do
  set -- $pair
  "${K[@]}" -n langfuse create secret tls "$1" --cert="$TLS/$2.pem" --key="$TLS/$2.key" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
done
echo "  CA $TLS/ca.pem · secrets lf-web-tls, lf-gateway-tls"

echo "════ 4. Secrets values (generated once) ════"
SV="$RUN_DIR/helm-secrets.yaml"
if [[ ! -s "$SV" ]]; then
  ( umask 077; cat > "$SV" <<EOT
langfuse:
  salt: { value: "$(openssl rand -hex 16)" }
  encryptionKey: { value: "$(openssl rand -hex 32)" }
  nextauth: { secret: { value: "$(openssl rand -hex 32)" } }
  additionalEnv:
    - { name: LANGFUSE_INIT_ORG_ID, value: "$LANGFUSE_INIT_ORG_ID" }
    - { name: LANGFUSE_INIT_ORG_NAME, value: "$LANGFUSE_INIT_ORG_NAME" }
    - { name: LANGFUSE_INIT_PROJECT_ID, value: "$LANGFUSE_INIT_PROJECT_ID" }
    - { name: LANGFUSE_INIT_PROJECT_NAME, value: "$LANGFUSE_INIT_PROJECT_NAME" }
    - { name: LANGFUSE_INIT_PROJECT_PUBLIC_KEY, value: "$LANGFUSE_INIT_PROJECT_PUBLIC_KEY" }
    - { name: LANGFUSE_INIT_PROJECT_SECRET_KEY, value: "$LANGFUSE_INIT_PROJECT_SECRET_KEY" }
    - { name: LANGFUSE_INIT_USER_EMAIL, value: "$LANGFUSE_INIT_USER_EMAIL" }
    - { name: LANGFUSE_INIT_USER_NAME, value: "$LANGFUSE_INIT_USER_NAME" }
    - { name: LANGFUSE_INIT_USER_PASSWORD, value: "$LANGFUSE_INIT_USER_PASSWORD" }
postgresql: { auth: { password: "$(openssl rand -hex 16)" } }
redis: { auth: { password: "$(openssl rand -hex 16)" } }
clickhouse: { auth: { password: "$(openssl rand -hex 16)" } }
s3: { auth: { rootPassword: "$(openssl rand -hex 16)" } }
EOT
  )
  echo "  wrote $SV"
fi

echo "════ 5. langfuse chart 2.2.3 with the gateway ════"
"${H[@]}" upgrade --install langfuse langfuse/langfuse --version 2.2.3 -n langfuse \
  -f "$HD/values.yaml" -f "$SV" --timeout 20m >/dev/null
"${K[@]}" -n langfuse wait --for=condition=Ready clickhousecluster/langfuse --timeout=15m >/dev/null
"${K[@]}" -n langfuse rollout status deploy/langfuse-web --timeout=15m >/dev/null
"${K[@]}" -n langfuse rollout status deploy/langfuse-worker --timeout=10m >/dev/null
"${K[@]}" -n langfuse rollout status deploy/langfuse-gateway --timeout=10m >/dev/null
# The worker loads Langfuse's default model prices once at start. On a first install it can start before
# Postgres answers; the load then fails ("Error upserting default model prices", seen 2026-11-05) and is
# not retried, so no model matches and every cost is 0. Restart the worker once if that happened.
# (Logs into a variable first: under pipefail, `kubectl logs | grep -q` fails when grep exits early.)
worker_log="$("${K[@]}" -n langfuse logs deploy/langfuse-worker 2>/dev/null || true)"
if grep -q "Error upserting default model prices" <<<"$worker_log"; then
  echo "  worker could not load the default model prices at start; restarting it"
  "${K[@]}" -n langfuse rollout restart deploy/langfuse-worker >/dev/null
  "${K[@]}" -n langfuse rollout status deploy/langfuse-worker --timeout=10m >/dev/null
fi
"${K[@]}" -n langfuse get deploy -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,WANT:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image --no-headers | sed 's/^/  /'

echo "════ 6. Over TLS from the host ════"
for u in https://langfuse.127.0.0.1.nip.io:18443/api/public/health https://gateway.127.0.0.1.nip.io:18443/health https://gateway.127.0.0.1.nip.io:18443/ready; do
  printf '  %-58s %s\n' "$u" "$(curl -sS --cacert "$TLS/ca.pem" "$u")"
done
echo "✅ next: .venv-v4/bin/python labs/v4/ai-gateway/14-helm-check.py"
