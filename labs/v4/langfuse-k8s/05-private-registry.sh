#!/usr/bin/env bash
# 05-private-registry.sh — the setup a regulated customer on AKS + ACR would have, rebuilt on kind:
# a private registry that needs a login, every image and chart of this lab mirrored into it, and nodes
# that cannot pull from anywhere else. Run it FIRST, on no cluster, then the usual scripts with
# PRIVATE_REGISTRY=1 (README, "Install from a private registry"):
#
#   1. CA, server certificate, htpasswd user, pull config            (.private-registry/, gitignored)
#   2. kind cluster (kind-config.yaml + containerd reads /etc/containerd/certs.d)
#   3. registry:2 with TLS and htpasswd on the kind network as privreg.lab.test (host: localhost:5443)
#   4. mirror private-registry-images.txt: images with crane (all platforms, digest kept), the two OCI
#      charts with crane, the langfuse chart with helm push; record source and mirror digests
#   5. lock the nodes: containerd sends docker.io, ghcr.io, quay.io, registry.k8s.io, mcr.microsoft.com,
#      docker.langfuse.com and any other registry (_default) to a dead endpoint; privreg.lab.test is the
#      only one with a host, trusted through the lab CA
#   6. the pull Secret in every namespace that pulls; the standins default ServiceAccount carries it
#   7. pull controls: a public image fails, the private one fails without the Secret, passes with it
#
# Stand-in for ACR, not run: `az acr import` copies an image between registries keeping its digest, as
# crane does here; `az aks update --attach-acr` gives the kubelet identity AcrPull, so no pull Secret.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/private-registry.inc.sh"
for c in kind kubectl helm openssl htpasswd docker jq; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
CLUSTER=langfuse-k8s; K="kubectl --context kind-$CLUSTER"
CRANE_IMAGE=gcr.io/go-containerregistry/crane:v0.20.3
REGISTRY_IMAGE=docker.io/library/registry:2.8.3
crane() { docker run --rm --network kind -v "$STATE:/s:ro" -e SSL_CERT_DIR=/s/ca -e DOCKER_CONFIG=/s/docker "$CRANE_IMAGE" "$@"; }
ROWS=""; FAILS=0
row() {  # row <check> <expected> <observed> <ok:0|1>
  local res=PASS; [ "$4" = 1 ] || { res=FAIL; FAILS=$((FAILS+1)); }
  printf -v ROWS '%s%s\t%s\t%s\t%s\n' "$ROWS" "$1" "$2" "$3" "$res"
  echo "  $res  $1 | expected: $2 | observed: $3"
}

echo "════ 1. CA, server certificate, htpasswd, pull config ════"
mkdir -p "$STATE/ca" "$STATE/certs" "$STATE/auth" "$STATE/docker"; chmod 700 "$STATE"
if [ ! -f "$STATE/certs/registry.crt" ]; then
  openssl req -x509 -newkey rsa:3072 -nodes -days 30 -subj "/CN=langfuse-k8s lab CA" \
    -keyout "$STATE/ca/ca.key" -out "$CA_FILE" 2>/dev/null
  openssl req -newkey rsa:3072 -nodes -subj "/CN=$REG_HOST" -keyout "$STATE/certs/registry.key" \
    -out "$STATE/certs/registry.csr" 2>/dev/null
  printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' "$REG_HOST" > "$STATE/certs/ext.cnf"
  openssl x509 -req -in "$STATE/certs/registry.csr" -CA "$CA_FILE" -CAkey "$STATE/ca/ca.key" -CAcreateserial -CAserial "$STATE/ca.srl" \
    -days 30 -extfile "$STATE/certs/ext.cnf" -out "$STATE/certs/registry.crt" 2>/dev/null
  mv "$STATE/ca/ca.key" "$STATE/ca.key"   # keep only the certificate in ca/ (crane reads every file there)
fi
if [ ! -f "$STATE/auth/htpasswd" ]; then
  openssl rand -hex 16 > "$STATE/password"; chmod 600 "$STATE/password"
  htpasswd -Bbn "$REG_USER" "$(cat "$STATE/password")" > "$STATE/auth/htpasswd"
fi
AUTH=$(printf '%s:%s' "$REG_USER" "$(cat "$STATE/password")" | base64 | tr -d '\n')
jq -n --arg a "$AUTH" --arg r "$REG_HOST" --arg h "$HELM_HOST" '{auths: {($r): {auth: $a}, ($h): {auth: $a}}}' > "$STATE/docker/config.json"
cp "$STATE/docker/config.json" "$HELM_REGISTRY_CONFIG"
echo "  CA and certificate for $REG_HOST, localhost; user $REG_USER (password in .private-registry/password)"

echo "════ 2. kind cluster with containerd hosts config (/etc/containerd/certs.d) ════"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  docker exec "$CLUSTER-control-plane" grep -q 'certs.d' /etc/containerd/config.toml ||
    { echo "✗ cluster $CLUSTER exists without the containerd hosts config: ./99-down.sh first"; exit 1; }
else
  { cat "$HERE/kind-config.yaml"; printf '%s\n' 'containerdConfigPatches:' '  - |-' \
      '    [plugins."io.containerd.grpc.v1.cri".registry]' '      config_path = "/etc/containerd/certs.d"'; } > "$STATE/kind-config.yaml"
  kind create cluster --config "$STATE/kind-config.yaml" --wait 120s
fi
NODES=$(kind get nodes --name "$CLUSTER" | sort)
echo "  nodes: $(echo $NODES)"

echo "════ 3. registry:2 with TLS and htpasswd as $REG_HOST (host side $HELM_HOST) ════"
if ! docker ps --format '{{.Names}}' | grep -qx "$REG_CONTAINER"; then
  docker rm -f "$REG_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$REG_CONTAINER" --restart=no --network kind --network-alias "$REG_HOST" -p 127.0.0.1:5443:443 \
    -v "$STATE/certs:/certs:ro" -v "$STATE/auth:/auth:ro" -v "$REG_VOLUME:/var/lib/registry" \
    -e REGISTRY_HTTP_ADDR=0.0.0.0:443 -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
    -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=lab \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd "$REGISTRY_IMAGE" >/dev/null
fi
for _ in $(seq 1 30); do curl -s -o /dev/null --cacert "$CA_FILE" "https://$HELM_HOST/v2/" && break; sleep 1; done
o=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA_FILE" "https://$HELM_HOST/v2/")
[ "$o" = 401 ] && ok=1 || ok=0; row "registry without credentials (/v2/)" 401 "$o" $ok
o=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA_FILE" -u "$REG_USER:$(cat "$STATE/password")" "https://$HELM_HOST/v2/")
[ "$o" = 200 ] && ok=1 || ok=0; row "registry with credentials (/v2/)" 200 "$o" $ok

echo "════ 4. mirror images and charts ($(grep -c '^image' "$HERE/private-registry-images.txt") images, $(grep -c '^chart' "$HERE/private-registry-images.txt") charts) ════"
LOG="$STATE/mirrored.tsv"; : > "$LOG"
mirror() {  # mirror <source ref without scheme> → copy with all platforms, compare digests, log
  local src="$1" dst="$REG_HOST/$1" sd dd
  crane cp "$src" "$dst" >/dev/null 2>&1 || crane cp "$src" "$dst" >/dev/null
  sd=$(crane digest "$src"); dd=$(crane digest "$dst")
  printf '%s\t%s\t%s\t%s\n' "$src" "$dst" "$sd" "$dd" >> "$LOG"
  [ "$sd" = "$dd" ] && echo "  = $src  $sd" || { echo "  ✗ $src  source $sd, mirror $dd"; return 1; }
}
while read -r typ ref _; do
  case "$typ" in
    image) mirror "$ref" ;;
    chart) case "$ref" in oci://*) mirror "${ref#oci://}" ;; esac ;;
  esac
done < <(grep -E '^(image|chart)' "$HERE/private-registry-images.txt")
# The langfuse chart is published in a classic Helm repository, not OCI: pull it, push it as an OCI artifact.
helm repo add langfuse https://langfuse.github.io/langfuse-k8s >/dev/null 2>&1 || true
helm repo update langfuse >/dev/null
rm -f "$STATE/langfuse-2.2.1.tgz"; helm pull langfuse/langfuse --version 2.2.1 -d "$STATE" >/dev/null
out=$(helm push "$STATE/langfuse-2.2.1.tgz" "oci://$HELM_HOST/charts" --ca-file "$CA_FILE" 2>&1)
cd_=$(echo "$out" | awk '/^Digest:/{print $2}')
printf '%s\t%s\t%s\t%s\n' "https://langfuse.github.io/langfuse-k8s langfuse 2.2.1" "$REG_HOST/charts/langfuse:2.2.1" \
  "sha256:$(shasum -a 256 "$STATE/langfuse-2.2.1.tgz" | cut -d' ' -f1) (tgz)" "$cd_" >> "$LOG"
echo "  + langfuse chart 2.2.1 → oci://$REG_HOST/charts/langfuse  $cd_"
n=$(awk -F'\t' '$3==$4' "$LOG" | wc -l | tr -d ' '); t=$(($(wc -l < "$LOG" | tr -d ' ') - 1))
[ "$n" = "$t" ] && ok=1 || ok=0; row "mirrored with the source digest (crane copies)" "$t of $t" "$n of $t" $ok

echo "════ 5. lock the nodes: no registry but $REG_HOST ════"
dead='server = "https://127.0.0.1:9"\n[host."https://127.0.0.1:9"]\n  capabilities = ["pull", "resolve"]\n'
for n in $NODES; do
  docker exec "$n" sh -c "set -e; d=/etc/containerd/certs.d
    for r in _default docker.io ghcr.io quay.io registry.k8s.io mcr.microsoft.com docker.langfuse.com gcr.io; do
      mkdir -p \$d/\$r; printf '$dead' > \$d/\$r/hosts.toml; done
    mkdir -p \$d/$REG_HOST"
  docker cp "$CA_FILE" "$n:/etc/containerd/certs.d/$REG_HOST/ca.crt" >/dev/null
  docker exec "$n" sh -c "printf 'server = \"https://$REG_HOST\"\n[host.\"https://$REG_HOST\"]\n  capabilities = [\"pull\", \"resolve\"]\n  ca = \"/etc/containerd/certs.d/$REG_HOST/ca.crt\"\n' > /etc/containerd/certs.d/$REG_HOST/hosts.toml"
done
echo "  certs.d on $(echo "$NODES" | wc -l | tr -d ' ') nodes: 8 blocked (_default + 7 named), $REG_HOST allowed"

echo "════ 6. pull Secret \`$PULL_SECRET\` in: $PR_NAMESPACES ════"
for ns in $PR_NAMESPACES; do
  $K create namespace "$ns" --dry-run=client -o yaml | $K apply -f - >/dev/null
  $K -n "$ns" create secret generic "$PULL_SECRET" --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$STATE/docker/config.json" --dry-run=client -o yaml | $K apply -f - >/dev/null
done
# standins.yaml and the blob-init pod are not charts: their namespace's default ServiceAccount carries the Secret.
$K -n standins patch serviceaccount default -p "{\"imagePullSecrets\":[{\"name\":\"$PULL_SECRET\"}]}" >/dev/null
echo "  done; standins default ServiceAccount carries it"

echo "════ 7. pull controls (namespace pull-controls, imagePullPolicy Always) ════"
C="$K -n pull-controls"
control() {  # control <name> <image> <with secret: 0|1>
  local ps=""; [ "$3" = 1 ] && ps=",\"imagePullSecrets\":[{\"name\":\"$PULL_SECRET\"}]"
  $C delete pod "$1" --ignore-not-found >/dev/null
  $C run "$1" --restart=Never --image="$2" --image-pull-policy=Always \
    --overrides="{\"spec\":{\"nodeSelector\":{\"workload\":\"app\"}$ps}}" --command -- true >/dev/null
}
waitpull() {  # waitpull <pod> → "pulled" or the pull error reason and message
  local r m
  for _ in $(seq 1 40); do
    r=$($C get pod "$1" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)
    case "$r" in Completed) echo pulled; return ;; ErrImagePull|ImagePullBackOff) break ;; esac; sleep 2
  done
  m=$($C get events --field-selector "involvedObject.name=$1,reason=Failed" -o jsonpath='{.items[0].message}' 2>/dev/null)
  echo "$r: $(echo "$m" | grep -oE '(connect: connection refused|401 Unauthorized|unauthorized|no basic auth credentials|not found)' | head -1)"
}
BB=docker.io/library/busybox:1.37.0
control public "$BB" 0
control private-no-secret "$REG_HOST/$BB" 0
o=$(waitpull public); case "$o" in *ImagePull*refused*) ok=1 ;; *) ok=0 ;; esac
row "public image $BB" "ErrImagePull/ImagePullBackOff, connection refused" "$o" $ok
o=$(waitpull private-no-secret); case "$o" in *ImagePull*401*|*ImagePull*nauthorized*|*ImagePull*credentials*) ok=1 ;; *) ok=0 ;; esac
row "private image, no pull Secret" "ErrImagePull/ImagePullBackOff, 401" "$o" $ok
control private-with-secret "$REG_HOST/$BB" 1
o=$(waitpull private-with-secret); [ "$o" = pulled ] && ok=1 || ok=0
row "private image with pull Secret" pulled "$o" $ok
$C delete pod --all --wait=false >/dev/null

echo; echo "════ Summary ════"; printf '%s' "$ROWS" | column -t -s $'\t'; echo
if [ "$FAILS" = 0 ]; then echo "✅ all $(printf '%s' "$ROWS" | grep -c .) checks passed. Next: PRIVATE_REGISTRY=1 ./01-kind-up.sh"
else echo "✗ $FAILS check(s) failed"; exit 1; fi
