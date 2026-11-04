#!/usr/bin/env bash
# 03-failures.sh — does every observation arrive when one component dies under load?
#
# Per scenario: a steady load of 1,200 traces/min × 4 observations (20 traces/s) for 150 s, every trace
# tagged with its run id, POSTs retried like the Python SDK 4.17.0 default (opentelemetry-python OTLP/HTTP
# exporter rule, 5 s deadline = LANGFUSE_TIMEOUT). At t = 30 s one container is killed (SIGKILL), it stays
# down OUTAGE seconds (default 20), then it is started again. During the outage the script samples where the
# raw events are: the BullMQ otel-ingestion-queue in Redis (wait / delayed / active / failed) and MinIO's
# PutObject counter. After the load it waits until the run's rows stop changing for 60 s (BullMQ retries a
# failed job after 5, 10, 20, 40, 80 s). Then: expected (accepted by the server) vs arrived observations.
#
#   Usage: ./03-failures.sh [component ...]     components: worker web clickhouse redis minio (default all)
#   Env:   OUTAGE=20  RETRY_DEADLINE=5
# Writes results/03-failures.jsonl and results/03-<component>-samples.tsv. Ends on the normal OSS stack.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OUTAGE="${OUTAGE:-20}"
RETRY_DEADLINE="${RETRY_DEADLINE:-5}"
OUT="$RESULTS/03-failures.jsonl"
comps=("$@"); [[ ${#comps[@]} -eq 0 ]] && comps=(worker web clickhouse redis minio)

rcli() { docker exec "$LF_PROJECT-redis-1" redis-cli -a "${REDIS_AUTH:-myredissecret}" --no-auth-warning "$@" 2>/dev/null; }
queue_state() {   # wait delayed active failed of the OTel ingestion queue (blank while Redis is down)
  local w d a f
  w=$(rcli LLEN bull:otel-ingestion-queue:wait); d=$(rcli ZCARD bull:otel-ingestion-queue:delayed)
  a=$(rcli LLEN bull:otel-ingestion-queue:active); f=$(rcli ZCARD bull:otel-ingestion-queue:failed)
  echo "${w:-?} ${d:-?} ${a:-?} ${f:-?}"
}
settle_long() {   # rows unchanged for 60 s, at most 6 min
  local run="$1" last=-1 same=0 cur
  for _ in $(seq 1 72); do
    cur=$(ch "SELECT count() FROM events_full WHERE has(tags, '$run')" 2>/dev/null || echo -1)
    if [[ "$cur" == "$last" ]]; then same=$((same + 1)); [[ $same -ge 12 ]] && return 0; else same=0; fi
    last="$cur"; sleep 5
  done
}

for comp in "${comps[@]}"; do
  ctr="$LF_PROJECT-langfuse-$comp-1"; [[ "$comp" =~ ^(clickhouse|redis|minio)$ ]] && ctr="$LF_PROJECT-$comp-1"
  run="f-$comp-$(date +%s)"
  samples="$RESULTS/03-$comp-samples.tsv"
  printf 't_s\tphase\tq_wait\tq_delayed\tq_active\tq_failed\ts3_put\n' > "$samples"
  failed0=$(rcli ZCARD bull:otel-ingestion-queue:failed)
  echo "▶ $comp: load 150 s, kill at 30 s, down ${OUTAGE} s  (run $run)"
  lgfile="$(mktemp)"
  "$PY" "$HERE/loadgen.py" --run-id "$run" --rpm 1200 --seconds 150 --retry-deadline "$RETRY_DEADLINE" > "$lgfile" &
  lgpid=$!
  t0=$(date +%s)
  sample() { local q p; q=$(queue_state); p=$(s3_counts 2>/dev/null | cut -d' ' -f1 || true); printf '%s\t%s\t%s\t%s\n' "$(( $(date +%s) - t0 ))" "$1" "${q// /$'\t'}" "${p:-?}" >> "$samples"; }
  while (( $(date +%s) - t0 < 30 )); do sample before; sleep 5; done
  docker kill "$ctr" >/dev/null
  kill_at=$(( $(date +%s) - t0 ))
  while (( $(date +%s) - t0 < 30 + OUTAGE )); do sample down; sleep 4; done
  docker start "$ctr" >/dev/null
  start_at=$(( $(date +%s) - t0 ))
  [[ "$comp" =~ ^(web|worker)$ ]] && wait_healthy
  while kill -0 "$lgpid" 2>/dev/null; do sample after; sleep 5; done
  wait "$lgpid" || true
  lg=$(tail -1 "$lgfile"); rm -f "$lgfile"
  settle_long "$run"
  sample settled
  failed1=$(rcli ZCARD bull:otel-ingestion-queue:failed)
  arrived=$(ch "SELECT count() FROM events_full WHERE has(tags, '$run')")
  jq -c --arg c "$comp" --argjson o "$OUTAGE" --argjson k "$kill_at" --argjson s "$start_at" \
        --argjson a "$arrived" --arg f0 "${failed0:-0}" --arg f1 "${failed1:-0}" \
     '{component: $c, outage_s: $o, killed_at_s: $k, started_at_s: $s} + . +
      {arrived_obs: $a, server_loss_obs: (.accepted_obs - $a), client_dropped_obs: (.failed_obs // 0),
       bullmq_failed_jobs_new: (($f1|tonumber) - ($f0|tonumber))}' <<<"$lg" | tee -a "$OUT" |
    jq -r '"  sent \(.sent_obs)  accepted \(.accepted_obs)  arrived \(.arrived_obs)  server loss \(.server_loss_obs)  client dropped \(.client_dropped_obs)  http \(.http)  retries \(.retries // 0)  failed jobs +\(.bullmq_failed_jobs_new)"'
  docker logs --since "$(( $(date +%s) - t0 + 30 ))s" "$LF_PROJECT-langfuse-worker-1" 2>&1 |
    grep -E "dropped|Max attempts|Failed job otel|ECONNREFUSED|error" | cut -c1-300 | sort | uniq -c | sort -rn | head -8 \
    > "$RESULTS/03-$comp-worker-log.txt" || true
done
