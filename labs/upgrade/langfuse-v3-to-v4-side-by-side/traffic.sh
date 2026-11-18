#!/usr/bin/env bash
# traffic.sh start|stop|report — one OpenTelemetry trace per second from inside the cluster to the
# Service clients use (langfuse-app). OTLP/HTTP JSON with `x-langfuse-ingestion-version: 4`, so the
# same producer is accepted by v3 and by v4 in events_only (v4 refuses legacy trace writes).
# Log line per request: <unix-ts> <http-code> <trace-id>.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
pod=lab-traffic
case ${1:?start|stop|report} in
start)
  auth=$(printf '%s:%s' "$LF_PK" "$LF_SK" | base64)
  kx -n "$NS" delete pod "$pod" --ignore-not-found --wait=true >/dev/null
  kx -n "$NS" run "$pod" --restart=Never --image=curlimages/curl:8.11.1 --env=AUTH="$auth" --env=TAG="${2:-traffic}" --command -- sh -c '
    n=0
    while [ ! -f /tmp/stop ]; do
      n=$((n+1)); ts=$(date +%s); tid=$(printf "%016x%016x" "$ts" "$n"); sid=$(printf "%016x" "$n")
      body="{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"traffic\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"lab-traffic\"},\"spans\":[{\"traceId\":\"$tid\",\"spanId\":\"$sid\",\"name\":\"traffic\",\"kind\":1,\"startTimeUnixNano\":\"${ts}000000000\",\"endTimeUnixNano\":\"${ts}500000000\",\"attributes\":[{\"key\":\"langfuse.trace.name\",\"value\":{\"stringValue\":\"traffic\"}},{\"key\":\"langfuse.trace.tags\",\"value\":{\"arrayValue\":{\"values\":[{\"stringValue\":\"$TAG\"}]}}}]}]}]}]}"
      code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" -X POST http://langfuse-app:3000/api/public/otel/v1/traces \
        -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" -H "x-langfuse-ingestion-version: 4" -d "$body")
      echo "$ts $code $tid"
      sleep 1
    done' >/dev/null
  kx -n "$NS" wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null
  echo "traffic started" ;;
stop)
  # sh is PID 1 and ignores SIGTERM, so the loop is told to stop and the log read after it exits.
  out=${2:-$WORK/traffic.log}
  kx -n "$NS" exec "$pod" -- touch /tmp/stop
  kx -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=60s >/dev/null
  kx -n "$NS" logs "$pod" >"$out"
  kx -n "$NS" delete pod "$pod" --wait=false >/dev/null
  echo "traffic stopped: $(wc -l <"$out") requests -> $out" ;;
report)
  f=${2:-$WORK/traffic.log}
  awk '{c[$2]++} END {for (k in c) printf "http %s: %d\n", k, c[k]}' "$f"
  awk '$2 !~ /^20/ {if (!f) f=$1; l=$1; n++} END {if (n) printf "failed requests: %d, first %s, last %s, window %ds\n", n, f, l, l-f+1; else print "failed requests: 0"}' "$f" ;;
esac
