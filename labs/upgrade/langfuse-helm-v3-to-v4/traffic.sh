#!/usr/bin/env bash
# traffic.sh start|stop|report — one legacy-API trace per second from inside the cluster to the
# Service clients use (langfuse-app), so the chart migration runs under live writes.
# The log line per request is: <unix-ts> <http-code> <trace-id>.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
pod=lab-traffic
case ${1:?start|stop|report} in
start)
  auth=$(printf '%s:%s' "$LF_PK" "$LF_SK" | base64)
  kx -n "$NS" delete pod "$pod" --ignore-not-found --wait=true >/dev/null
  kx -n "$NS" run "$pod" --restart=Never --image=curlimages/curl:8.11.1 --env=AUTH="$auth" --command -- sh -c '
    n=0
    while [ ! -f /tmp/stop ]; do
      n=$((n+1)); ts=$(date +%s); id="traffic-$ts-$n"
      now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
      code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" -X POST http://langfuse-app:3000/api/public/ingestion \
        -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" \
        -d "{\"batch\":[{\"id\":\"$id-e\",\"type\":\"trace-create\",\"timestamp\":\"$now\",\"body\":{\"id\":\"$id\",\"name\":\"traffic\",\"tags\":[\"phase:traffic\"]}}]}")
      echo "$ts $code $id"
      sleep 1
    done' >/dev/null
  kx -n "$NS" wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null
  echo "traffic started" ;;
stop)
  # sh is PID 1 and ignores SIGTERM, so the loop is told to stop and the log read after it exits.
  kx -n "$NS" exec "$pod" -- touch /tmp/stop
  kx -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=60s >/dev/null
  kx -n "$NS" logs "$pod" >"$WORK/traffic.log"
  kx -n "$NS" delete pod "$pod" --wait=false >/dev/null
  echo "traffic stopped: $(wc -l <"$WORK/traffic.log") requests -> $WORK/traffic.log" ;;
report)
  log=${2:-$WORK/traffic.log}
  awk '{c[$2]++} END {for (k in c) printf "http %s: %d\n", k, c[k]}' "$log"
  # Failure window: first and last non-2xx request.
  awk '$2 !~ /^20/ {if (!f) f=$1; l=$1; n++} END {if (n) printf "failed requests: %d, first %s, last %s, window %ds\n", n, f, l, l-f+1; else print "failed requests: 0"}' "$log" ;;
esac
