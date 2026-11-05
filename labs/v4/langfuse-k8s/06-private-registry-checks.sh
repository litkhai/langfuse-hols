#!/usr/bin/env bash
# 06-private-registry-checks.sh — after PRIVATE_REGISTRY=1 ./01-kind-up.sh, ./02-install.sh and ./03-checks.sh:
# did anything come from outside the private registry?
#
#   A. spec      every container and init container image in the lab's namespaces names the registry
#   B. status    every running container's imageID (the digest the kubelet resolved) is from the registry,
#                and equals the source digest 05-private-registry.sh recorded
#   C. events    every Pulling / Pulled event names the registry; no pull failed (pull-controls aside)
#   D. nodes     every image in containerd on the 5 nodes is from the registry or preloaded by kind
#   E. lock      the nodes' containerd hosts config is still in place (a public pull would fail)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/private-registry.inc.sh"
K="kubectl --context kind-langfuse-k8s"
NS="cert-manager clickhouse-operator standins langfuse"
ROWS=""; FAILS=0
row() {  # row <check> <expected> <observed> <ok:0|1>
  local res=PASS; [ "$4" = 1 ] || { res=FAIL; FAILS=$((FAILS+1)); }
  printf -v ROWS '%s%s\t%s\t%s\t%s\n' "$ROWS" "$1" "$2" "$3" "$res"
  echo "  $res  $1 | expected: $2 | observed: $3"
}
pods_json() { for ns in $NS; do $K -n "$ns" get pods -o json; done | jq -s '[.[].items[]]'; }
P=$(pods_json)

echo "════ A. Image references in the pod specs ════"
refs=$(echo "$P" | jq -r '.[] | .spec.containers[], (.spec.initContainers // [])[] | .image' | sort -u)
out=$(echo "$refs" | grep -v "^$REG_HOST/" || true)
echo "$refs" | sed 's/^/    /'
row "pods in $NS" "$(echo "$P" | jq length) pods, every image $REG_HOST/…" \
  "$(echo "$refs" | grep -c .) distinct images, $(echo "$out" | grep -c . || true) elsewhere" "$([ -z "$out" ] && echo 1 || echo 0)"

echo "════ B. Resolved digests (containerStatuses[].imageID) ════"
ids=$(echo "$P" | jq -r '.[] | (.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[] | "\(.image) \(.imageID)"' | sort -u)
out=$(echo "$ids" | awk -v r="$REG_HOST/" 'index($2, r) != 1' || true)
row "imageID of every container" "$REG_HOST/…@sha256:…" "$(echo "$ids" | grep -c .) distinct, $(echo "$out" | grep -c . || true) elsewhere" "$([ -z "$out" ] && echo 1 || echo 0)"
bad=0; n=0
while read -r image id; do
  n=$((n+1)); src="${image#"$REG_HOST/"}"; want=$(awk -F'\t' -v s="$src" '$1 == s {print $3}' "$STATE/mirrored.tsv")
  [ "${id##*@}" = "$want" ] || { bad=$((bad+1)); echo "    ✗ $image resolved ${id##*@}, source $want"; }
done <<< "$ids"
row "resolved digest = source digest (mirrored.tsv)" "$n of $n" "$((n-bad)) of $n" "$([ "$bad" = 0 ] && echo 1 || echo 0)"

echo "════ C. Pull events (kept 1 h by the API server) ════"
ev=$(for ns in $NS; do $K -n "$ns" get events -o json; done | jq -s '[.[].items[]]')
pulls=$(echo "$ev" | jq -r '.[] | select(.reason == "Pulling" or .reason == "Pulled") | .message')
img=$(echo "$pulls" | grep -oE 'image "[^"]+"' | sort -u)
out=$(echo "$img" | grep -v "image \"$REG_HOST/" || true)
row "Pulling/Pulled events" "every image $REG_HOST/…" "$(echo "$pulls" | grep -c .) events, $(echo "$img" | grep -c .) images, $(echo "$out" | grep -c . || true) elsewhere" "$([ -z "$out" ] && echo 1 || echo 0)"
f=$(echo "$ev" | jq '[.[] | select(.reason == "Failed" and (.message | test("pull|image"; "i")))] | length')
row "pull failures in $NS" 0 "$f" "$([ "$f" = 0 ] && echo 1 || echo 0)"

echo "════ D. Images in containerd on every node ════"
bad=0; tot=0
for n in $(kind get nodes --name langfuse-k8s | sort); do
  # Per image: preloaded if a tag is kindest/ or registry.k8s.io/ (their repoDigests read
  # docker.io/library/import-<date>, kind's import name); otherwise every tag and digest must be the registry's.
  imgs=$(docker exec "$n" crictl images -o json)
  other=$(echo "$imgs" | jq -r --arg r "$REG_HOST/" '.images[]
    | select(any(.repoTags[]?; startswith("docker.io/kindest/") or startswith("registry.k8s.io/")) | not)
    | (.repoTags[]?, .repoDigests[]?) | select(startswith($r) | not)' | sort -u)
  priv=$(echo "$imgs" | jq -r --arg r "$REG_HOST/" '[.images[].repoTags[]? | select(startswith($r))] | length')
  tot=$((tot + priv)); [ -z "$other" ] || { bad=$((bad+1)); echo "    ✗ $n: $other"; }
  echo "    $n: $priv tags from $REG_HOST, rest preloaded by kind (kindest/, registry.k8s.io/)"
done
row "containerd images on 5 nodes" "registry or kind preload only" "$tot registry tags, $bad nodes with others" "$([ "$bad" = 0 ] && echo 1 || echo 0)"

echo "════ E. Lock still in place ════"
c=0; for n in $(kind get nodes --name langfuse-k8s); do
  docker exec "$n" grep -q '127.0.0.1:9' /etc/containerd/certs.d/_default/hosts.toml /etc/containerd/certs.d/docker.io/hosts.toml && c=$((c+1))
done
row "nodes with public registries sent to a dead endpoint" 5 "$c" "$([ "$c" = 5 ] && echo 1 || echo 0)"

echo; echo "════ Summary ════"; printf '%s' "$ROWS" | column -t -s $'\t'; echo
if [ "$FAILS" = 0 ]; then echo "✅ all $(printf '%s' "$ROWS" | grep -c .) checks passed"; else echo "✗ $FAILS check(s) failed"; exit 1; fi
