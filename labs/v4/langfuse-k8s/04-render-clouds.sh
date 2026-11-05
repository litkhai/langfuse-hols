#!/usr/bin/env bash
# 04-render-clouds.sh — values-base.yaml + each cloud file (AKS, EKS, GKE), without the kind overlay:
# render, validate against a real Kubernetes API (the kind cluster, CRDs installed) with a server-side
# dry run, and assert the sizing and the cloud-specific wiring. The <…> placeholders are replaced with
# example values first; nothing is applied.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="kubectl --context kind-langfuse-k8s"
for c in helm kubectl uv; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ROWS=""; FAILS=0
row() { local res=PASS; [ "$4" = 1 ] || { res=FAIL; FAILS=$((FAILS+1)); }
  printf -v ROWS '%s%s\t%s\t%s\t%s\n' "$ROWS" "$1" "$2" "$3" "$res"; echo "  $res  $1 | expected: $2 | observed: $3"; }
eq() { [ "$2" = "$3" ] && ok=1 || ok=0; row "$1" "$2" "$3" $ok; }

# fill <file> → the file with every <…> replaced: the ingress host by a real-looking name, the rest by "x"
fill() { sed -e 's/<langfuse.example.internal>/langfuse.example.com/g' -e 's/<[^>]*>/x/g' "$1"; }

# Field facts from the rendered documents (PyYAML through uv), one "key<TAB>value" per line
facts() {
  uv run -q --no-project --python 3.12 --with pyyaml==6.0.2 python - "$1" <<'PY'
import sys, re, yaml
def get(d, *path):
    for p in path:
        if isinstance(d, list): d = d[p] if len(d) > p else None
        elif isinstance(d, dict): d = d.get(p)
        else: return None
    return d
out = {}
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not isinstance(d, dict): continue
    k, n = d.get('kind'), get(d, 'metadata', 'name')
    if k == 'Deployment':
        c = get(d, 'spec', 'template', 'spec', 'containers', 0)
        env = {e['name']: e.get('value') for e in c.get('env', []) if 'name' in e}
        out[n] = f"replicas={get(d,'spec','replicas') or 'HPA'} req={get(c,'resources','requests','cpu')}/{get(c,'resources','requests','memory')} pool={get(d,'spec','template','spec','nodeSelector','workload')}"
        if n.endswith('web'):
            out['liveness'] = str(get(c, 'livenessProbe', 'initialDelaySeconds'))
            out['cluster'] = str(env.get('CLICKHOUSE_CLUSTER_ENABLED'))
            out['db'] = str(env.get('DATABASE_HOST'))
            out['redis'] = re.sub(r'//[^@]*@[^:/]*', '//***@host', env.get('REDIS_CONNECTION_STRING') or '') + (' ca=' + env['REDIS_TLS_CA_PATH'] if env.get('REDIS_TLS_CA_PATH') else '')
            blob = 'azure' if env.get('LANGFUSE_USE_AZURE_BLOB') == 'true' else 'gcs' if env.get('LANGFUSE_USE_GOOGLE_CLOUD_STORAGE') == 'true' else 's3'
            keys = 'static-key' if env.get('LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID') or any(e.get('name') == 'LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID' for e in c.get('env', [])) else 'no-key'
            out['objects'] = f"{blob} {keys}"
    elif k == 'HorizontalPodAutoscaler':
        out['hpa-' + n] = f"{get(d,'spec','minReplicas')}-{get(d,'spec','maxReplicas')}"
    elif k == 'ClickHouseCluster':
        s = d['spec']
        out['clickhouse'] = f"replicas={s.get('replicas')} shards={s.get('shards', 1)} req={get(s,'containerTemplate','resources','requests','cpu')}/{get(s,'containerTemplate','resources','requests','memory')} disk={get(s,'dataVolumeClaimSpec','resources','requests','storage')} pool={get(s,'podTemplate','nodeSelector','workload')} taint={get(s,'podTemplate','tolerations',0,'value')}"
        out['class'] = str(get(s, 'dataVolumeClaimSpec', 'storageClassName'))
    elif k == 'KeeperCluster':
        out['keeper'] = f"replicas={get(d,'spec','replicas')} class={get(d,'spec','dataVolumeClaimSpec','storageClassName')}"
    elif k == 'Ingress':
        a = get(d, 'metadata', 'annotations') or {}
        out['ingress'] = f"class={get(d,'spec','ingressClassName')} annotation={a.get('kubernetes.io/ingress.class')} tls={bool(get(d,'spec','tls'))}"
    elif k == 'ServiceAccount':
        a = get(d, 'metadata', 'annotations') or {}
        out['identity'] = ','.join(k2 for k2 in a if k2 in ('eks.amazonaws.com/role-arn', 'iam.gke.io/gcp-service-account')) or 'none'
for k, v in out.items(): print(f"{k}\t{v}")
PY
}

declare_expect() {  # per-cloud expectations: class, ingress, redis, objects, identity, extra manifest
  case "$1" in
    aks) X_CLASS=managed-csi-premium; X_ING="class=webapprouting.kubernetes.azure.com annotation=None tls=True"
         X_REDIS="rediss://***@host:10000/0"; X_OBJ="azure static-key"; X_ID=none; X_EXTRA="" ;;
    eks) X_CLASS=langfuse-gp3; X_ING="class=None annotation=alb tls=False"
         X_REDIS="rediss://***@host:6379/0"; X_OBJ="s3 no-key"; X_ID=eks.amazonaws.com/role-arn; X_EXTRA="$HERE/storageclass-eks.yaml" ;;
    gke) X_CLASS=premium-rwo; X_ING="class=None annotation=gce tls=True"
         X_REDIS="rediss://***@host:6378/0 ca=/etc/memorystore-ca/server-ca.pem"; X_OBJ="gcs no-key"; X_ID=iam.gke.io/gcp-service-account; X_EXTRA="" ;;
  esac
}

for cloud in aks eks gke; do
  echo "════ $cloud: values-base.yaml + values-$cloud.yaml ════"
  declare_expect "$cloud"
  fill "$HERE/values-base.yaml" > "$TMP/base.yaml"; fill "$HERE/values-$cloud.yaml" > "$TMP/cloud.yaml"
  left=$(cat "$TMP/base.yaml" "$TMP/cloud.yaml" | grep -c '<[a-z]' || true); eq "$cloud: placeholders left" 0 "$left"
  helm template langfuse langfuse/langfuse --version 2.2.1 -n langfuse-render -f "$TMP/base.yaml" -f "$TMP/cloud.yaml" \
    --api-versions clickhouse.com/v1alpha1/ClickHouseCluster --api-versions clickhouse.com/v1alpha1/KeeperCluster > "$TMP/out.yaml"
  [ -n "$X_EXTRA" ] && { echo "---"; cat "$X_EXTRA"; } >> "$TMP/out.yaml"
  $K create namespace langfuse-render --dry-run=client -o yaml | $K apply -f - >/dev/null
  out=$($K apply --dry-run=server -n langfuse-render -f "$TMP/out.yaml" 2>&1) && ok=1 || ok=0
  row "$cloud: kubectl apply --dry-run=server" "accepted" "$(echo "$out" | grep -c 'server dry run') objects$( [ $ok = 1 ] || echo ": $(echo "$out" | grep -i error | head -1)")" $ok
  $K delete namespace langfuse-render --wait=true --timeout=120s >/dev/null   # a terminating namespace would reject the next dry run
  facts "$TMP/out.yaml" > "$TMP/facts.tsv"
  f() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$TMP/facts.tsv"; }
  # the same on every cloud (values-base.yaml)
  eq "$cloud: langfuse-web" "replicas=HPA req=2/4Gi pool=app" "$(f langfuse-web)"
  eq "$cloud: langfuse-worker" "replicas=HPA req=2/4Gi pool=app" "$(f langfuse-worker)"
  eq "$cloud: HPA web, worker" "2-4 2-6" "$(f hpa-langfuse-web) $(f hpa-langfuse-worker)"
  eq "$cloud: web liveness initialDelaySeconds" 300 "$(f liveness)"
  eq "$cloud: ClickHouseCluster" "replicas=3 shards=1 req=6/24Gi disk=1850Gi pool=clickhouse taint=clickhouse" "$(f clickhouse)"
  eq "$cloud: CLICKHOUSE_CLUSTER_ENABLED" true "$(f cluster)"
  # what the cloud file decides
  eq "$cloud: storage class (ClickHouse)" "$X_CLASS" "$(f class)"
  eq "$cloud: KeeperCluster" "replicas=3 class=$X_CLASS" "$(f keeper)"
  eq "$cloud: Ingress" "$X_ING" "$(f ingress)"
  eq "$cloud: Redis" "$X_REDIS" "$(f redis)"
  eq "$cloud: object storage, credentials" "$X_OBJ" "$(f objects)"
  eq "$cloud: workload identity annotation" "$X_ID" "$(f identity)"
done

echo; echo "════ Summary ════"; printf '%s' "$ROWS" | column -t -s $'\t'; echo
if [ "$FAILS" = 0 ]; then echo "✅ all $(printf '%s' "$ROWS" | grep -c .) checks passed"; else echo "✗ $FAILS check(s) failed"; exit 1; fi
