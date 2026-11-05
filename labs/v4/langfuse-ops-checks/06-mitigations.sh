#!/usr/bin/env bash
# 06-mitigations.sh — do the three loss mitigations proposed after test 03 actually help?
#
# Same load and outage as 03: 1,200 traces/min × 4 observations (10 KB in + 1 KB out each), one trace per POST,
# 150 s; the component is SIGKILLed at t = 35 s and started at t = 55 s. Expected = observations the client got
# a 2xx for; arrived = distinct span_id of the run in events_full after the rows are unchanged for 60 s.
#
#   lb             two web replicas behind HAProxy (overlay web2, haproxy-web2.cfg); web-1 killed; SDK retry 5 s
#   lb-noretry     the same with haproxy-web2-noretry.cfg (health checks, no retries) — what the retries are worth
#   deadline30     one web, client retry deadline 30 s (= LANGFUSE_TIMEOUT=30), 64 sender threads as in 03
#   deadline30-t1024  the same with 1,024 threads, so no POST waits in the generator's queue: each POST retries
#                  on its own clock (closer to many processes with one exporter each)
#   sdk30 / sdk5   one web, the Langfuse Python SDK 4.17.0 itself in one process (06b-sdk-outage.py) with
#                  LANGFUSE_TIMEOUT 30 / 5: adds the SDK's span queue (2,048 spans, drops when full)
#   otel-web       client → OTel Collector (overlay otelcol, otelcol.yaml) → web; web killed
#   otel-minio     the same, MinIO killed (web answers 500)
#   otel-restart   the same, web down 30–60 s so the Collector's queue fills, Collector SIGKILLed at 35 s and
#                  started at 55 s with its file_storage queue on a volume
#
#   Usage: ./06-mitigations.sh [scenario ...]   (default: all of the above)
# Writes results/06-mitigations.jsonl, results/06-<scenario>-samples.tsv, results/06-otelcol-<scenario>-log.txt,
# results/06-<lb scenario>-haproxy-log.txt.
# Ends on the normal OSS stack (extra containers and the Collector's volume removed).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OUT="$RESULTS/06-mitigations.jsonl"
scen=("$@"); [[ ${#scen[@]} -eq 0 ]] && scen=(lb lb-noretry deadline30 deadline30-t1024 sdk30 sdk5 otel-web otel-minio otel-restart)
WEB="$LF_PROJECT-langfuse-web-1"; MINIO="$LF_PROJECT-minio-1"; OTELCOL="$LF_PROJECT-otelcol-1"
LOAD=(--rpm 1200 --seconds 150 --obs 4 --prompt-bytes 10000 --output-bytes 1000 --traces-per-post 1)

wait_url() { local i; for i in $(seq 1 90); do curl -fsS -o /dev/null "$1" 2>/dev/null && return 0; sleep 2; done; echo "✗ $1 not up" >&2; return 1; }
up() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | sed 's/true/up/; s/false/down/'; }
otel_metrics() {   # queue size, spans sent, spans failed to send (cumulative) of the Collector
  local m; m=$(curl -fsS localhost:18888/metrics 2>/dev/null) || { printf '?\t?\t?'; return 0; }
  awk '
    /^otelcol_exporter_queue_size\{/ {q=$2} /^otelcol_exporter_sent_spans(_total)?\{/ {s=$2}
    /^otelcol_exporter_send_failed_spans(_total)?\{/ {f=$2}
    END {printf "%s\t%s\t%s", (q==""?"?":q), (s==""?"?":s), (f==""?"0":f)}' <<<"$m"
}
extras_down() {
  for c in langfuse-web-2 lb otelcol; do docker rm -f "$LF_PROJECT-$c-1" >/dev/null 2>&1 || true; done
  docker volume rm "${LF_PROJECT}_otelcol_queue" >/dev/null 2>&1 || true
}
record() {   # record <scenario> <json> — append and print one line
  jq -c --arg s "$1" '{scenario: $s} + .' <<<"$2" | tee -a "$OUT" |
    jq -r '"  sent \(.sent_obs)  accepted \(.accepted_obs // "?")  arrived \(.arrived_obs)  loss \(.loss_obs)  server loss \(.server_loss_obs)  client dropped \(.client_dropped_obs)  http \(.http)  retries \(.retries // 0)  events \([.events[] | "\(.[1])s \(.[2] | split(" ") | .[0:2] | join(" "))"] | join(", "))"'
}

for s in "${scen[@]}"; do
  run="m-$s-$(date +%s)"
  samples="$RESULTS/06-$s-samples.tsv"
  echo "▶ $s  (run $run)"
  case "$s" in
    lb|lb-noretry)
      extras_down
      cfg=haproxy-web2.cfg; [[ $s == lb-noretry ]] && cfg=haproxy-web2-noretry.cfg
      HAPROXY_CFG="$cfg" ops_compose web2 -- up -d --no-deps langfuse-web-2 lb >/dev/null 2>&1
      wait_url http://localhost:3080/api/public/health
      # warm both replicas (first requests compile routes) and wait until HAProxy has both UP
      LANGFUSE_HOST=http://localhost:3080 "$PY" "$HERE/loadgen.py" --run-id "warmup-06-$(date +%s)" --rpm 1200 --seconds 20 >/dev/null
      for _ in $(seq 1 30); do
        [[ "$(docker logs "$LF_PROJECT-lb-1" 2>&1 | grep -E 'web/web2 is (UP|DOWN)' | tail -1)" != *DOWN* ]] && break; sleep 2
      done
      sleep 5
      t_log=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      printf 't_s\tweb1\tweb2\n' > "$samples"
      ops_sample() { printf '%s\t%s' "$(up "$WEB")" "$(up "$LF_PROJECT-langfuse-web-2-1")"; }
      res=$(LANGFUSE_HOST=http://localhost:3080 timeline_load "$run" "$samples" \
              "35 docker kill $WEB" "55 docker start $WEB" -- "${LOAD[@]}" --retry-deadline 5)
      res=$(jq -c --arg c "$cfg" '. + {lb_config: $c}' <<<"$res")
      docker logs --since "$t_log" "$LF_PROJECT-lb-1" 2>&1 | cut -c1-240 > "$RESULTS/06-$s-haproxy-log.txt" || true
      ;;
    deadline30|deadline30-t1024)
      extras_down
      th=64; [[ $s == deadline30-t1024 ]] && th=1024
      printf 't_s\tweb\n' > "$samples"
      ops_sample() { up "$WEB"; }
      res=$(timeline_load "$run" "$samples" "35 docker kill $WEB" "55 docker start $WEB" -- \
              "${LOAD[@]}" --retry-deadline 30 --threads "$th")
      ;;
    sdk30|sdk5)
      extras_down
      printf 't_s\tweb\n' > "$samples"
      ops_sample() { up "$WEB"; }
      res=$(LOADGEN=06b-sdk-outage.py timeline_load "$run" "$samples" "35 docker kill $WEB" "55 docker start $WEB" -- \
              --rpm 1200 --seconds 150 --obs 4 --prompt-bytes 10000 --output-bytes 1000 --retry-deadline "${s#sdk}")
      ;;
    otel-web|otel-minio|otel-restart)
      if [[ "$(up "$OTELCOL")" != up ]]; then
        extras_down
        ops_compose otelcol -- up -d --no-deps otelcol >/dev/null 2>&1
        sleep 5
      fi
      printf 't_s\tweb\tminio\totelcol\tqueue_size\tsent_spans\tsend_failed_spans\n' > "$samples"
      ops_sample() { printf '%s\t%s\t%s\t%s' "$(up "$WEB")" "$(up "$MINIO")" "$(up "$OTELCOL")" "$(otel_metrics)"; }
      t_log=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      case "$s" in
        otel-web)     ev=("35 docker kill $WEB" "55 docker start $WEB") ;;
        otel-minio)   ev=("35 docker kill $MINIO" "55 docker start $MINIO") ;;
        otel-restart) ev=("30 docker kill $WEB" "35 docker kill $OTELCOL" "55 docker start $OTELCOL" "60 docker start $WEB") ;;
      esac
      res=$(timeline_load "$run" "$samples" "${ev[@]}" -- "${LOAD[@]}" --retry-deadline 5 \
              --endpoint http://localhost:4318/v1/traces)
      docker logs --since "$t_log" "$OTELCOL" 2>&1 | grep -E '"?level"?.?(warn|error)|Dropping|dropped|retry|Retry|permanent|Permanent' |
        sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z//; s/"trace_id":"[^"]*"//g' | cut -c1-260 | sort | uniq -c | sort -rn | head -12 \
        > "$RESULTS/06-otelcol-$s-log.txt" || true
      res=$(jq -c --arg m "$(otel_metrics)" '. + {otelcol_queue_sent_failed_end: $m}' <<<"$res")
      ;;
    *) echo "unknown scenario $s" >&2; exit 2 ;;
  esac
  wait_healthy
  record "$s" "$res"
done
echo "▶ removing web-2, lb, otelcol and the Collector's volume"
extras_down
wait_healthy
