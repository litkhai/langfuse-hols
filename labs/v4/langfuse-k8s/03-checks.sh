#!/usr/bin/env bash
# 03-checks.sh — does the AKS layout come up as intended, and does it keep working when parts fail?
#
#   A. placement   ClickHouse 3 replicas on 3 different `clickhouse` nodes; web, worker and Keeper on
#                  `app`; HPA minimum 2; PDBs; ClickHouse 1 shard × 3 replicas; replicated tables
#   B. wiring      Langfuse talks to ClickHouse in cluster mode, to Blob in Azure mode, and to the
#                  external Postgres and Redis (the stand-ins)
#   C. data path   a trace through the public API lands on all 3 replicas, its raw event in the Blob
#                  container, the project in Postgres
#   D. failover    one ClickHouse replica deleted: ingestion and reads go on, the replica comes back
#                  with the missed rows; one Keeper deleted: ingestion goes on
set -euo pipefail
K="kubectl --context kind-langfuse-k8s -n langfuse"
S="kubectl --context kind-langfuse-k8s -n standins"
PORT=13000
ROWS=""; FAILS=0
row() {  # row <check> <expected> <observed> <ok:0|1>
  local res=PASS; [ "$4" = 1 ] || { res=FAIL; FAILS=$((FAILS+1)); }
  printf -v ROWS '%s%s\t%s\t%s\t%s\n' "$ROWS" "$1" "$2" "$3" "$res"
  echo "  $res  $1 | expected: $2 | observed: $3"
}
sec() { $K get secret langfuse -o "jsonpath={.data.$1}" | base64 -d; }
CHPW=$(sec clickhouse-password); PK=$(sec init-public-key); SK=$(sec init-secret-key)
chq() { $K exec "$1" -- clickhouse-client --password "$CHPW" -q "$2"; }
node_pool() { kubectl --context kind-langfuse-k8s get node "$1" -o jsonpath='{.metadata.labels.workload}'; }

echo "════ A. Placement ════"
nodes=$($K get pods -l clickhouse.com/role=clickhouse-server -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)
pools=$(for n in $nodes; do node_pool "$n"; echo; done | sort -u | paste -sd, -)
[ "$(echo "$nodes" | grep -c .)" = 3 ] && [ "$pools" = clickhouse ] && ok=1 || ok=0
row "ClickHouse replicas: distinct nodes, pool" "3 nodes, clickhouse" "$(echo "$nodes" | grep -c .) nodes, $pools" $ok
other=$($K get pods -l 'app.kubernetes.io/name in (web,worker)' -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null)
other="$other
$($K get pods -l clickhouse.com/role=clickhouse-keeper -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}')"
pools=$(for n in $(echo "$other" | grep .); do node_pool "$n"; echo; done | sort -u | paste -sd, -)
[ "$pools" = app ] && ok=1 || ok=0; row "web, worker, Keeper pool" app "$pools" $ok
o=$($K get clickhousecluster langfuse -o jsonpath='{.status.readyReplicas}/{.spec.replicas}') ; [ "$o" = 3/3 ] && ok=1 || ok=0
row "ClickHouseCluster ready replicas" 3/3 "$o" $ok
o=$($K get keepercluster langfuse -o jsonpath='{.status.readyReplicas}/{.spec.replicas}'); [ "$o" = 3/3 ] && ok=1 || ok=0
row "KeeperCluster ready replicas" 3/3 "$o" $ok
o=$($K get hpa langfuse-web langfuse-worker -o jsonpath='{range .items[*]}{.spec.minReplicas}-{.spec.maxReplicas} {end}' | xargs)
[ "$o" = "2-4 2-6" ] && ok=1 || ok=0; row "HPA web, worker (min-max)" "2-4 2-6" "$o" $ok
o=$($K get pdb --no-headers | awk '{print $1}' | sort | paste -sd' ' -)
row "PodDisruptionBudgets" "clickhouse, keeper, web, worker" "$o" "$([ "$(echo "$o" | wc -w | tr -d ' ')" = 4 ] && echo 1 || echo 0)"
CH0=langfuse-clickhouse-0-0-0
o=$(chq $CH0 "SELECT concat(toString(max(shard_num)), ' shard, ', toString(uniqExact(replica_num)), ' replicas') FROM system.clusters WHERE cluster = 'default'")
[ "$o" = "1 shard, 3 replicas" ] && ok=1 || ok=0; row "cluster 'default'" "1 shard, 3 replicas" "$o" $ok
o=$(chq $CH0 "SELECT groupUniqArray(engine) FROM system.tables WHERE database = 'default' AND name IN ('events_full', 'events_core', 'scores')")
[ "$o" = "['ReplicatedReplacingMergeTree']" ] && ok=1 || ok=0; row "engine of events_full, events_core, scores" "['ReplicatedReplacingMergeTree']" "$o" $ok

echo "════ B. Wiring (langfuse-web environment) ════"
envv() { $K exec deploy/langfuse-web -- printenv "$1" 2>/dev/null || true; }
o="$(envv CLICKHOUSE_CLUSTER_ENABLED) $(envv LANGFUSE_USE_AZURE_BLOB) $(envv DATABASE_HOST) $(envv REDIS_TLS_ENABLED)"
[ "$o" = "true true postgres.standins.svc.cluster.local false" ] && ok=1 || ok=0
row "CLICKHOUSE_CLUSTER_ENABLED, LANGFUSE_USE_AZURE_BLOB, DATABASE_HOST, REDIS_TLS_ENABLED" "true true postgres.standins… false" "$o" $ok
o=$(envv REDIS_CONNECTION_STRING | sed -E 's#//[^@]*@#//***@#'); case "$o" in *redis.standins.svc.cluster.local:6379*) ok=1 ;; *) ok=0 ;; esac
row "Redis connection" "redis.standins…:6379" "$o" $ok

echo "════ C. Data path ════"
$K port-forward svc/langfuse-web $PORT:3000 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/public/health" && break; sleep 1; done
H="http://127.0.0.1:$PORT"
o=$(curl -s -o /dev/null -w '%{http_code}' "$H/api/public/health"); [ "$o" = 200 ] && ok=1 || ok=0; row "web health through the Service" 200 "$o" $ok

send() {  # send <text> → trace id
  local tid; tid=$(openssl rand -hex 16); local nano; nano="$(date +%s)000000000"
  jq -n --arg tid "$tid" --arg sid "$(openssl rand -hex 8)" --arg n "$nano" --arg v "$1" \
    '{resourceSpans:[{resource:{attributes:[{key:"service.name",value:{stringValue:"aks-lab"}}]},
      scopeSpans:[{scope:{name:"aks-lab"},spans:[{traceId:$tid,spanId:$sid,name:"aks-lab",kind:1,
      startTimeUnixNano:$n,endTimeUnixNano:$n,attributes:[{key:"langfuse.observation.input",value:{stringValue:$v}}]}]}]}]}' |
    curl -sS -m 30 -o /dev/null -w '%{http_code}' -u "$PK:$SK" -X POST "$H/api/public/otel/v1/traces" \
      -H "Content-Type: application/json" -H "x-langfuse-ingestion-version: 4" -d @- >/dev/null
  echo "$tid"
}
read_back() {  # read_back <trace id> <expected input> → "ok" or what came back (waits for async ingestion)
  local v=""
  for _ in $(seq 1 60); do
    v=$(curl -s -m 30 -u "$PK:$SK" "$H/api/public/v2/observations?traceId=$1&fields=core,io" | jq -r '.data[0].input // empty' 2>/dev/null || true)
    [ "$v" = "$2" ] && { echo ok; return; }; sleep 3
  done
  echo "${v:-nothing}"
}
on_replicas() {  # on_replicas <trace id> → "a b c": rows of that trace on each replica
  local out=""
  for p in langfuse-clickhouse-0-0-0 langfuse-clickhouse-0-1-0 langfuse-clickhouse-0-2-0; do
    out="$out $(chq $p "SELECT count() FROM default.events_full WHERE trace_id = '$1'" 2>/dev/null || echo x)"
  done
  echo "${out# }"
}
wait_replicas() {  # wait_replicas <trace id> → counts once every replica has the row (or after 90 s)
  local c=""
  for _ in $(seq 1 30); do c=$(on_replicas "$1"); [ "$c" = "1 1 1" ] && break; sleep 3; done
  echo "$c"
}

S1="aks-lab-$(openssl rand -hex 8)"; T1=$(send "$S1")
o=$(read_back "$T1" "$S1"); [ "$o" = ok ] && ok=1 || ok=0; row "trace through the public API" "read back" "$o" $ok
o=$(wait_replicas "$T1"); [ "$o" = "1 1 1" ] && ok=1 || ok=0; row "its row on replica 0, 1, 2" "1 1 1" "$o" $ok
n=$($S exec deploy/azurite -- sh -c "grep -rl '$S1' /data 2>/dev/null | wc -l" | tr -d ' ')
[ "$n" -ge 1 ] && ok=1 || ok=0; row "raw event in the Blob stand-in (Azurite)" ">=1 file" "$n" $ok
o=$($S exec deploy/postgres -- psql -U langfuse -d langfuse -tAc "SELECT count(*) FROM projects WHERE id = 'kind-project'")
[ "$o" = 1 ] && ok=1 || ok=0; row "project in the Postgres stand-in" 1 "$o" $ok

echo "════ D. Failover ════"
$K delete pod langfuse-clickhouse-0-1-0 --wait=false >/dev/null
S2="aks-lab-$(openssl rand -hex 8)"; T2=$(send "$S2")
o=$(read_back "$T2" "$S2"); [ "$o" = ok ] && ok=1 || ok=0; row "replica 1 deleted: trace ingested and read" "read back" "$o" $ok
$K wait --for=condition=Ready pod/langfuse-clickhouse-0-1-0 --timeout=300s >/dev/null
o=$(wait_replicas "$T2"); [ "$o" = "1 1 1" ] && ok=1 || ok=0; row "replica 1 back: rows of that trace on 0, 1, 2" "1 1 1" "$o" $ok

$K delete pod langfuse-keeper-1-0 --wait=false >/dev/null
S3="aks-lab-$(openssl rand -hex 8)"; T3=$(send "$S3")
o=$(read_back "$T3" "$S3"); [ "$o" = ok ] && ok=1 || ok=0; row "Keeper 1 deleted: trace ingested and read" "read back" "$o" $ok
$K wait --for=condition=Ready pod/langfuse-keeper-1-0 --timeout=300s >/dev/null
o=$(wait_replicas "$T3"); [ "$o" = "1 1 1" ] && ok=1 || ok=0; row "Keeper 1 back: rows of that trace on 0, 1, 2" "1 1 1" "$o" $ok

echo; echo "════ Summary ════"; printf '%s' "$ROWS" | column -t -s $'\t'; echo
if [ "$FAILS" = 0 ]; then echo "✅ all $(printf '%s' "$ROWS" | grep -c .) checks passed"; else echo "✗ $FAILS check(s) failed"; exit 1; fi
