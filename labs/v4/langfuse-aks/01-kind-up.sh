#!/usr/bin/env bash
# 01-kind-up.sh — a kind cluster shaped like the AKS layout, the two prerequisites, the stand-ins
# for the Azure managed services, and the `langfuse` Secret that values-aks.yaml reads.
#
# Pins: kind node image = kind's default; cert-manager v1.20.2 and clickhouse-operator 0.0.8, the
# versions the langfuse 2.2.1 chart README lists. Secrets are generated here and never printed; the
# Enterprise licence key is copied from _base/.env when present (EE features on, as on the AKS values).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
for c in kind kubectl helm openssl; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
K="kubectl --context kind-langfuse-aks"

echo "════ 1. kind cluster (control plane, 1 app worker, 3 tainted clickhouse workers) ════"
kind get clusters 2>/dev/null | grep -qx langfuse-aks || kind create cluster --config "$HERE/kind-config.yaml" --wait 120s
$K get nodes -L agentpool --no-headers | awk '{print "  "$1, (NF>5 ? $NF : "-")}'

echo "════ 2. cert-manager v1.20.2 and clickhouse-operator 0.0.8 ════"
helm --kube-context kind-langfuse-aks upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.20.2 --namespace cert-manager --create-namespace --set crds.enabled=true --wait >/dev/null
$K wait --for=condition=Established crd/certificates.cert-manager.io crd/issuers.cert-manager.io --timeout=120s >/dev/null
helm --kube-context kind-langfuse-aks upgrade --install clickhouse-operator oci://ghcr.io/clickhouse/clickhouse-operator-helm \
  --version 0.0.8 --namespace clickhouse-operator --create-namespace --wait >/dev/null
$K wait --for=condition=Established crd/clickhouseclusters.clickhouse.com crd/keeperclusters.clickhouse.com --timeout=120s >/dev/null
echo "  CRDs established"

echo "════ 3. Stand-ins for Azure Postgres, Redis and Blob (namespace standins) ════"
PG_PW=$(openssl rand -hex 16); REDIS_PW=$(openssl rand -hex 16); AZ_KEY=$(openssl rand -base64 64 | tr -d '\n')
if ! $K get secret standins -n standins >/dev/null 2>&1; then
  $K create namespace standins --dry-run=client -o yaml | $K apply -f - >/dev/null
  $K create secret generic standins -n standins --from-literal=postgresql-password="$PG_PW" \
    --from-literal=redis-password="$REDIS_PW" --from-literal=azurite-accounts="langfuselab:$AZ_KEY" >/dev/null
fi
$K apply -f "$HERE/standins.yaml" >/dev/null
$K -n standins rollout status deploy/postgres deploy/redis deploy/azurite --timeout=180s >/dev/null
echo "  postgres, redis, azurite ready"
# The Blob container must exist before Langfuse writes to it: Langfuse 4.70.1 did not create it, on
# upload or at startup (the PUT answered 404 ContainerNotFound). On Azure, create it with the storage
# account (IaC). Here: the Azure SDK that ships in the Langfuse image, as a one-off pod.
SDK=/app/node_modules/.pnpm/@azure+storage-blob@12.26.0_supports-color@8.1.1/node_modules/@azure/storage-blob
$K -n standins delete pod blob-init --ignore-not-found >/dev/null
$K -n standins run blob-init --restart=Never --image=docker.langfuse.com/langfuse/langfuse:4.70.1 \
  --overrides='{"spec":{"nodeSelector":{"agentpool":"app"}}}' \
  --env="AZKEY=$($K get secret standins -n standins -o jsonpath='{.data.azurite-accounts}' | base64 -d | cut -d: -f2-)" \
  --command -- node -e "
const {BlobServiceClient,StorageSharedKeyCredential}=require('$SDK');
new BlobServiceClient('http://azurite.standins.svc.cluster.local:10000/langfuselab', new StorageSharedKeyCredential('langfuselab', process.env.AZKEY))
  .getContainerClient('langfuse').createIfNotExists().then(r => console.log('container langfuse created:', r.succeeded));" >/dev/null
$K -n standins wait --for=jsonpath='{.status.phase}'=Succeeded pod/blob-init --timeout=300s >/dev/null
echo "  $($K -n standins logs blob-init) (false = it already existed)"
$K -n standins delete pod blob-init >/dev/null

echo "════ 4. The \`langfuse\` Secret (the keys values-aks.yaml reads) ════"
$K create namespace langfuse --dry-run=client -o yaml | $K apply -f - >/dev/null
if ! $K get secret langfuse -n langfuse >/dev/null 2>&1; then
  sv() { $K get secret standins -n standins -o "jsonpath={.data.$1}" | base64 -d; }
  $K create secret generic langfuse -n langfuse \
    --from-literal=nextauth-secret="$(openssl rand -hex 32)" --from-literal=salt="$(openssl rand -hex 32)" \
    --from-literal=encryption-key="$(openssl rand -hex 32)" --from-literal=license-key="${LANGFUSE_EE_LICENSE_KEY:-}" \
    --from-literal=clickhouse-password="$(openssl rand -hex 16)" \
    --from-literal=postgresql-password="$(sv postgresql-password)" --from-literal=redis-password="$(sv redis-password)" \
    --from-literal=azure-storage-key="$(sv azurite-accounts | cut -d: -f2-)" >/dev/null
fi
# Project API keys for the checks (kind only: values-kind.yaml passes them as LANGFUSE_INIT_*).
if [ -z "$($K get secret langfuse -n langfuse -o jsonpath='{.data.init-public-key}')" ]; then
  $K patch secret langfuse -n langfuse --type merge -p "{\"stringData\":{\"init-public-key\":\"pk-lf-kind-$(openssl rand -hex 8)\",\"init-secret-key\":\"sk-lf-kind-$(openssl rand -hex 16)\"}}" >/dev/null
fi
echo "  secret langfuse: $($K get secret langfuse -n langfuse -o jsonpath='{.data}' | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin))))')"
echo
echo "✅ cluster ready. Next: ./02-install.sh"
