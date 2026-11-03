#!/usr/bin/env bash
# 04-render-aks.sh — values-aks.yaml ALONE (no kind overlay): render it, validate it against a real
# Kubernetes API (the kind cluster, CRDs installed) with a server-side dry run, and assert the sizing.
# The <…> placeholders are replaced with example values first; nothing is applied.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="kubectl --context kind-langfuse-aks"
for c in helm kubectl uv; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ROWS=""; FAILS=0
row() { local res=PASS; [ "$4" = 1 ] || { res=FAIL; FAILS=$((FAILS+1)); }
  printf -v ROWS '%s%s\t%s\t%s\t%s\n' "$ROWS" "$1" "$2" "$3" "$res"; echo "  $res  $1 | expected: $2 | observed: $3"; }

sed -e 's/<langfuse.example.internal>/langfuse.example.com/g' -e 's/<server>/lf-pg/' \
    -e 's/<name>\.<region>/lf-redis.koreacentral/' -e 's/<account>/lfstorage/g' "$HERE/values-aks.yaml" > "$TMP/values.yaml"
left=$(grep -c '<[a-z]' "$TMP/values.yaml" || true)
[ "$left" = 0 ] && ok=1 || ok=0; row "placeholders left after substitution" 0 "$left" $ok

helm template langfuse langfuse/langfuse --version 2.2.1 -n langfuse-render -f "$TMP/values.yaml" \
  --api-versions clickhouse.com/v1alpha1/ClickHouseCluster --api-versions clickhouse.com/v1alpha1/KeeperCluster > "$TMP/out.yaml"
kinds=$(grep -E '^kind: ' "$TMP/out.yaml" | sort | uniq -c | awk '{print $3"="$1}' | paste -sd' ' -)
row "rendered kinds" "Deployment×2, HPA×2, PDB×2, Ingress, ClickHouseCluster, KeeperCluster, …" "$kinds" 1

$K create namespace langfuse-render --dry-run=client -o yaml | $K apply -f - >/dev/null
out=$($K apply --dry-run=server -n langfuse-render -f "$TMP/out.yaml" 2>&1) && ok=1 || ok=0
row "kubectl apply --dry-run=server (kind API, CRDs installed)" "accepted" "$(echo "$out" | grep -c 'created (server dry run)') objects$( [ $ok = 1 ] || echo ": $(echo "$out" | grep -i error | head -1)")" $ok
$K delete namespace langfuse-render --wait=true --timeout=120s >/dev/null   # a terminating namespace would reject the next dry run

# Field checks: Python (PyYAML through uv) reads the rendered documents
uv run -q --no-project --python 3.12 --with pyyaml==6.0.2 python - "$TMP/out.yaml" > "$TMP/facts.tsv" <<'PY'
import sys, json, re
docs, cur = [], []
for line in open(sys.argv[1]):
    if line.startswith('---'):
        if cur: docs.append(''.join(cur)); cur = []
    else: cur.append(line)
if cur: docs.append(''.join(cur))
try:
    import yaml
except ImportError:
    yaml = None
facts = {}
def get(d, *path):
    for p in path:
        if isinstance(d, list): d = d[p] if len(d) > p else None
        elif isinstance(d, dict): d = d.get(p)
        else: return None
    return d
for t in docs:
    if yaml is None: break
    d = yaml.safe_load(t)
    if not isinstance(d, dict): continue
    k, n = d.get('kind'), get(d, 'metadata', 'name')
    if k == 'Deployment':
        c = get(d, 'spec', 'template', 'spec', 'containers', 0)
        env = {e['name']: e.get('value') for e in c.get('env', []) if 'name' in e}
        facts[n] = f"replicas={get(d,'spec','replicas') or 'HPA'} req={get(c,'resources','requests','cpu')}/{get(c,'resources','requests','memory')} pool={get(d,'spec','template','spec','nodeSelector','agentpool')}"
        if n.endswith('web'):
            facts['env'] = ' '.join(f"{k2}={env.get(k2)}" for k2 in ('CLICKHOUSE_CLUSTER_ENABLED','LANGFUSE_USE_AZURE_BLOB','DATABASE_HOST','REDIS_TLS_ENABLED')) + ' redis=' + re.sub(r'//[^@]*@', '//***@', env.get('REDIS_CONNECTION_STRING') or '')
    elif k == 'HorizontalPodAutoscaler':
        facts['hpa-' + n] = f"{get(d,'spec','minReplicas')}-{get(d,'spec','maxReplicas')}"
    elif k == 'ClickHouseCluster':
        s = d['spec']
        facts['clickhouse'] = f"replicas={s.get('replicas')} shards={s.get('shards', 1)} req={get(s,'containerTemplate','resources','requests','cpu')}/{get(s,'containerTemplate','resources','requests','memory')} storage={get(s,'dataVolumeClaimSpec','resources','requests','storage')} class={get(s,'dataVolumeClaimSpec','storageClassName')} pool={get(s,'podTemplate','nodeSelector','agentpool')} taint={get(s,'podTemplate','tolerations',0,'value')}"
    elif k == 'KeeperCluster':
        facts['keeper'] = f"replicas={get(d,'spec','replicas')}"
    elif k == 'Ingress':
        facts['ingress'] = f"class={get(d,'spec','ingressClassName')} host={get(d,'spec','rules',0,'host')} tls={bool(get(d,'spec','tls'))}"
for k, v in facts.items(): print(f"{k}\t{v}")
if yaml is None: print("error\tPyYAML missing")
PY
f() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$TMP/facts.tsv"; }
for d in langfuse-web langfuse-worker; do
  # With HPA on, the chart leaves spec.replicas out: the HPA (minimum 2) owns the count.
  o=$(f $d); [ "$o" = "replicas=HPA req=2/4Gi pool=app" ] && ok=1 || ok=0; row "$d" "replicas=HPA req=2/4Gi pool=app" "$o" $ok
done
o="$(f hpa-langfuse-web) $(f hpa-langfuse-worker)"; [ "$o" = "2-4 2-6" ] && ok=1 || ok=0; row "HPA web, worker" "2-4 2-6" "$o" $ok
o=$(f clickhouse); case "$o" in "replicas=3 shards=1 req=6/24Gi storage=512Gi class=managed-csi-premium pool=clickhouse taint=clickhouse") ok=1 ;; *) ok=0 ;; esac
row "ClickHouseCluster" "replicas=3 shards=1 req=6/24Gi storage=512Gi class=managed-csi-premium pool=clickhouse taint=clickhouse" "$o" $ok
o=$(f keeper); [ "$o" = "replicas=3" ] && ok=1 || ok=0; row "KeeperCluster" "replicas=3" "$o" $ok
o=$(f ingress); [ "$o" = "class=webapprouting.kubernetes.azure.com host=langfuse.example.com tls=True" ] && ok=1 || ok=0
row "Ingress" "class=webapprouting.kubernetes.azure.com host=langfuse.example.com tls=True" "$o" $ok
o=$(f env); [ "$o" = "CLICKHOUSE_CLUSTER_ENABLED=true LANGFUSE_USE_AZURE_BLOB=true DATABASE_HOST=lf-pg.postgres.database.azure.com REDIS_TLS_ENABLED=true redis=rediss://***@lf-redis.koreacentral.redis.azure.net:10000/0" ] && ok=1 || ok=0
row "web env (cluster mode, Azure Blob, Postgres, Redis TLS)" "…=true …=true DATABASE_HOST=lf-pg.postgres… REDIS_TLS_ENABLED=true redis=rediss://***@…:10000/0" "$o" $ok

echo; echo "════ Summary ════"; printf '%s' "$ROWS" | column -t -s $'\t'; echo
if [ "$FAILS" = 0 ]; then echo "✅ all $(printf '%s' "$ROWS" | grep -c .) checks passed"; else echo "✗ $FAILS check(s) failed"; exit 1; fi
