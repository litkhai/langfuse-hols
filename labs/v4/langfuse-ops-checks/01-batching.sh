#!/usr/bin/env bash
# 01-batching.sh — which knobs change the blob-storage (S3) call rate and the ClickHouse insert rate?
#
# Fixed load: 4,020 traces/min (67/s), 4 observations each, 10 KB input + 1 KB output per observation, 60 s.
# Each scenario recreates web + worker with its knobs (overlay `knobs`), runs the load, waits until the run's
# rows stop arriving, then reads MinIO's request counters (PutObject/GetObject) and system.query_log.
# Writes results/01-batching.jsonl (one line per scenario). Ends on the normal OSS stack.
#   Usage: ./01-batching.sh [seconds]      (default 60)
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SECS="${1:-60}"
OUT="$RESULTS/01-batching.jsonl"
: > "$OUT"
KNOBS=(LANGFUSE_INGESTION_CLICKHOUSE_WRITE_BATCH_SIZE LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS
       LANGFUSE_OTEL_INGESTION_QUEUE_PROCESSING_CONCURRENCY LANGFUSE_S3_CONCURRENT_WRITES
       LANGFUSE_TRACE_BATCH_INGESTION_ENABLED LANGFUSE_TRACE_BATCH_SAMPLING_RATE LANGFUSE_TRACE_BATCH_MAX_SIZE
       LANGFUSE_TRACE_BATCH_DISPATCHER_ENABLED QUEUE_CONSUMER_TRACE_BATCH_QUEUE_IS_ENABLED)

scenario() {   # scenario <label> <traces per POST> [VAR=value ...]
  local label="$1" tpp="$2"; shift 2
  local k; for k in "${KNOBS[@]}"; do unset "$k"; done
  local kv; for kv in "$@"; do export "${kv?}"; done
  echo "▶ $label  (traces/POST $tpp; ${*:-defaults})"
  ops_apply knobs
  local run="b-${label}-$(date +%s)"
  run_load "$run" --rpm 4020 --seconds "$SECS" --traces-per-post "$tpp" |
    jq -c --arg l "$label" --arg k "$*" '{scenario: $l, knobs: $k} + .' | tee -a "$OUT" |
    jq -r '"  POST/s \(.accepted_posts / .wall_s | . * 10 | round / 10)  S3 PUT/s \(.s3_put_per_s)  GET \(.s3_get)  CH inserts/s \(.ch_inserts_per_s)  rows \(.ch_rows_events_full)  lag p95 \(.lag_p95_s) s  loss \(.loss_obs)  [\(.ch_inserts_by_table)]"'
}

scenario defaults        1
scenario ch-write-batch  1 LANGFUSE_INGESTION_CLICKHOUSE_WRITE_BATCH_SIZE=10000 LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS=5000
scenario queue-conc      1 LANGFUSE_OTEL_INGESTION_QUEUE_PROCESSING_CONCURRENCY=20 LANGFUSE_S3_CONCURRENT_WRITES=10
scenario trace-batch     1 LANGFUSE_TRACE_BATCH_INGESTION_ENABLED=true LANGFUSE_TRACE_BATCH_SAMPLING_RATE=1 \
                           LANGFUSE_TRACE_BATCH_MAX_SIZE=600 LANGFUSE_TRACE_BATCH_DISPATCHER_ENABLED=true \
                           QUEUE_CONSUMER_TRACE_BATCH_QUEUE_IS_ENABLED=true
scenario client-10       10
scenario client-67       67

for k in "${KNOBS[@]}"; do unset "$k"; done
echo "▶ restoring the normal OSS stack"
ops_restore
