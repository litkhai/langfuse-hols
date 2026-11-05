# lib.sh — sourced by the numbered scripts of labs/v4/langfuse-ops-checks.
#
#   ops_compose [overlay ...] -- <compose args>
#       docker compose on the shared v4 stack (project langfuse-hols-v4) with extra overlays. An overlay name
#       is this lab's docker-compose.<name>.yml if it exists, else _base/docker-compose.<name>.yml (e.g. ee).
#   ops_apply [overlay ...]      recreate web + worker with those overlays and wait for health
#   ops_restore                  back to the normal OSS stack (the base file only, no lab overlay)
#   ch "<sql>"                   clickhouse-client in the stack's ClickHouse container (TSV out)
#   s3_counts                    "<putobject> <getobject>" from MinIO's request counters
#   measure <run_id> <loadgen json line>   one JSON line: what arrived, lag, inserts, blob calls
#   settle_quiet <run_id>        wait until the run's rows are unchanged for 60 s (at most 6 min)
#   timeline_load <run_id> <samples.tsv> "<t_s> <command>" ... -- <loadgen args>
#                                load with scheduled commands (kill, start, …), then expected vs arrived (06, 08)
#
# CH_CTR (default $LF_PROJECT-clickhouse-1) is the container `ch` talks to; 08 points it at a live replica.
# OPS_PROJECT replaces the compose project the helpers address (default langfuse-hols-v4).
#
# Knobs for the `knobs` overlay are plain shell variables (see docker-compose.knobs.yml); unset = Langfuse's
# own default.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../../_base/lib/env.sh" v4
load_env "${LF_ENV_FILE:-$BASE_DIR/.env}"
LF_PROJECT="${OPS_PROJECT:-$LF_PROJECT}"   # 08 runs a second compose project (langfuse-hols-v4ch3)
export LANGFUSE_HOST="${NEXTAUTH_URL:-http://localhost:3000}"
export LANGFUSE_PUBLIC_KEY="${LANGFUSE_INIT_PROJECT_PUBLIC_KEY:?missing in _base/.env}"
export LANGFUSE_SECRET_KEY="${LANGFUSE_INIT_PROJECT_SECRET_KEY:?missing in _base/.env}"
RESULTS="$HERE/results"
mkdir -p "$RESULTS"
PY="${PY:-$BASE_DIR/../.venv-v4/bin/python}"
[[ -x "$PY" ]] || PY=python3

ops_compose() {
  local -a files=(-f "$BASE_DIR/docker-compose.yml")
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    if [[ -f "$HERE/docker-compose.$1.yml" ]]; then files+=(-f "$HERE/docker-compose.$1.yml")
    else files+=(-f "$BASE_DIR/docker-compose.$1.yml"); fi
    shift
  done
  shift
  local -a envs=(--env-file "$TRACK_DIR/versions.env")
  local secrets="${LF_ENV_FILE:-$BASE_DIR/.env}"
  [[ -f "$secrets" ]] && envs+=(--env-file "$secrets")
  LF_TRACK="$TRACK" docker compose "${envs[@]}" "${files[@]}" "$@"
}

wait_healthy() {
  local i
  for i in $(seq 1 120); do
    if curl -fsS -o /dev/null "$LANGFUSE_HOST/api/public/health" 2>/dev/null &&
       curl -fsS -o /dev/null "http://localhost:3030/api/health" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "✗ web/worker not healthy after 240 s" >&2
  return 1
}

ops_apply() {
  local -a ov=("$@")
  local svcs=(langfuse-web langfuse-worker)
  local o
  for o in ${ov[@]+"${ov[@]}"}; do [[ "$o" == worker2 ]] && svcs+=(langfuse-worker-2); done
  [[ " ${svcs[*]} " == *" langfuse-worker-2 "* ]] || docker rm -f "$LF_PROJECT-langfuse-worker-2-1" >/dev/null 2>&1 || true
  ops_compose ${ov[@]+"${ov[@]}"} -- up -d --no-deps --force-recreate "${svcs[@]}" >/dev/null 2>&1
  wait_healthy
  sleep 5
}

ops_restore() {
  docker rm -f "$LF_PROJECT-langfuse-worker-2-1" >/dev/null 2>&1 || true
  lf_compose -- up -d --force-recreate langfuse-web langfuse-worker >/dev/null 2>&1
  wait_healthy
}

ch() {
  docker exec -i "${CH_CTR:-$LF_PROJECT-clickhouse-1}" clickhouse-client -u "${CLICKHOUSE_USER:-clickhouse}" \
    --password "${CLICKHOUSE_PASSWORD:-clickhouse}" -q "$1"
}

s3_counts() {
  docker exec "$LF_PROJECT-minio-1" sh -c \
    "mc alias set lab http://localhost:9000 '${MINIO_ROOT_USER:-minio}' '${MINIO_ROOT_PASSWORD:-miniosecret}' >/dev/null 2>&1; mc admin prometheus metrics lab 2>/dev/null" |
    awk '/^minio_s3_requests_total\{api="putobject"/ {p=$2} /^minio_s3_requests_total\{api="getobject"/ {g=$2} END {printf "%d %d\n", p, g}'
}

# wait until the run's observation count stops changing (10 s stable) or 180 s pass
settle() {
  local run="$1" last=-1 cur i
  for i in $(seq 1 36); do
    cur=$(ch "SELECT count() FROM events_full WHERE has(tags, '$run')")
    [[ "$cur" == "$last" ]] && return 0
    last="$cur"
    sleep 5
  done
}

# measure <run_id> <loadgen json> [put0 get0 put1 get1]
measure() {
  local run="$1" lg="$2"
  local start end
  start=$(jq -r '.started_unix' <<<"$lg")
  end=$(date +%s)   # through the settle phase, so late flushes count
  ch "SYSTEM FLUSH LOGS" >/dev/null
  local arrived
  arrived=$(ch "SELECT count(), uniqExact(trace_id),
      round(quantile(0.5)(dateDiff('millisecond', start_time, created_at))/1000, 2),
      round(quantile(0.95)(dateDiff('millisecond', start_time, created_at))/1000, 2),
      round(quantile(0.99)(dateDiff('millisecond', start_time, created_at))/1000, 2),
      round(max(dateDiff('millisecond', start_time, created_at))/1000, 2)
    FROM events_full WHERE has(tags, '$run') FORMAT JSONCompactEachRow")
  local ins
  ins=$(ch "SELECT count(), sum(written_rows) FROM system.query_log
     WHERE type = 'QueryFinish' AND query_kind = 'Insert' AND has(tables, 'default.events_full')
       AND event_time_microseconds BETWEEN fromUnixTimestamp64Milli(toInt64($start*1000))
                                       AND fromUnixTimestamp64Milli(toInt64($end*1000))
     FORMAT JSONCompactEachRow")
  local bytable
  bytable=$(ch "SELECT arrayStringConcat(groupArray(concat(t, '=', toString(c))), ' ') FROM (
     SELECT arrayJoin(tables) AS t, count() AS c FROM system.query_log
     WHERE type = 'QueryFinish' AND query_kind = 'Insert' AND user = currentUser()
       AND event_time_microseconds BETWEEN fromUnixTimestamp64Milli(toInt64($start*1000))
                                       AND fromUnixTimestamp64Milli(toInt64($end*1000))
     GROUP BY t ORDER BY t)")
  local putd="${5:-0}" getd="${6:-0}"
  [[ -n "${3:-}" ]] && { putd=$(( $5 - $3 )); getd=$(( $6 - $4 )); }
  jq -c --argjson a "$arrived" --argjson i "$ins" --argjson put "$putd" --argjson get "$getd" --arg bt "$bytable" '
    . + {arrived_obs: $a[0], arrived_traces: $a[1], lag_p50_s: $a[2], lag_p95_s: $a[3], lag_p99_s: $a[4],
         lag_max_s: $a[5], ch_inserts_events_full: $i[0], ch_rows_events_full: ($i[1]|tonumber),
         ch_inserts_per_s: (($i[0] / .wall_s * 10 | round) / 10),
         s3_put: $put, s3_get: $get, s3_put_per_s: (($put / .wall_s * 10 | round) / 10),
         ch_inserts_by_table: $bt, loss_obs: ((.accepted_obs // 0) - $a[0])}' <<<"$lg"
}

# run_load <run_id> <loadgen args...> — runs the generator with S3 counters around it, settles, measures
run_load() {
  local run="$1"; shift
  local c0 c1 lg
  c0=$(s3_counts)
  lg=$("$PY" "$HERE/loadgen.py" --run-id "$run" "$@")
  settle "$run"
  c1=$(s3_counts)
  # shellcheck disable=SC2086
  measure "$run" "$lg" $c0 $c1
}

# settle_quiet <run_id> — rows of the run unchanged for 60 s, at most 6 min (BullMQ retries after 5…80 s, a
# Collector after its own backoff). Same rule as 03's settle_long.
settle_quiet() {
  local run="$1" last=-1 same=0 cur
  for _ in $(seq 1 72); do
    cur=$(ch "SELECT count() FROM events_full WHERE has(tags, '$run')" 2>/dev/null || echo -1)
    if [[ "$cur" == "$last" ]]; then same=$((same + 1)); [[ $same -ge 12 ]] && return 0; else same=0; fi
    last="$cur"; sleep 5
  done
}

# timeline_load <run_id> <samples.tsv> "<t_s> <command>" ... -- <loadgen args>
#   Starts loadgen.py in the background and runs each command (eval'd) when <t_s> seconds have passed since the
#   start; commands must be in time order. Every 4 s it appends "t_s<TAB>$(ops_sample)" to the samples file if a
#   function ops_sample is defined. Then waits for the generator, settles, and prints one JSON line: the loadgen
#   line + {events: [[planned, actual, command]…], arrived_obs (distinct span_id), arrived_rows,
#   loss_obs (sent − arrived), server_loss_obs (accepted − arrived), client_dropped_obs (the client gave up)}.
#   LOADGEN=<script in this directory> swaps the generator (06b-sdk-outage.py: the SDK itself).
timeline_load() {
  local run="$1" samples="$2"; shift 2
  local -a ev=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do ev+=("$1"); shift; done
  shift
  local lgfile evfile t0 lgpid e at cmd now
  lgfile="$(mktemp)"; evfile="$(mktemp)"
  "$PY" "$HERE/${LOADGEN:-loadgen.py}" --run-id "$run" "$@" > "$lgfile" &
  lgpid=$!
  t0=$(date +%s)
  _tl_sample() { declare -F ops_sample >/dev/null && printf '%s\t%s\n' "$(( $(date +%s) - t0 ))" "$(ops_sample)" >> "$samples"; return 0; }
  for e in ${ev[@]+"${ev[@]}"}; do
    at="${e%% *}"; cmd="${e#* }"
    local el d
    while (( (el = $(date +%s) - t0) < at )); do _tl_sample; d=$(( at - el )); sleep $(( d < 4 ? d : 4 )); done
    now=$(( $(date +%s) - t0 ))
    eval "$cmd" >/dev/null 2>&1 || true
    jq -nc --argjson p "$at" --argjson a "$now" --arg c "$cmd" '[$p, $a, $c]' >> "$evfile"
  done
  while kill -0 "$lgpid" 2>/dev/null; do _tl_sample; sleep 4; done
  wait "$lgpid" || true
  settle_quiet "$run"
  _tl_sample
  local lg arr
  lg=$(tail -1 "$lgfile")
  arr=$(ch "SELECT uniqExact(span_id), count() FROM events_full WHERE has(tags, '$run') FORMAT JSONCompactEachRow")
  jq -c --argjson a "$arr" --slurpfile ev "$evfile" \
     '. + {events: $ev, arrived_obs: $a[0], arrived_rows: $a[1], loss_obs: (.sent_obs - $a[0]),
           server_loss_obs: (if .accepted_obs == null then null else .accepted_obs - $a[0] end),
           client_dropped_obs: (.failed_obs // 0)}' <<<"$lg"
  rm -f "$lgfile" "$evfile"
}
