#!/usr/bin/env bash
# 08-clickhouse-cluster.sh — Langfuse 4.56.0 on ClickHouse 1 shard × 3 replicas (+ one Keeper), under 03's load.
#
# Own compose project langfuse-hols-v4ch3 (base file + docker-compose.ch3.yml) on fresh volumes; the v4 stack is
# stopped meanwhile (same host ports) and started again at the end. Langfuse runs with
# CLICKHOUSE_CLUSTER_ENABLED=true and CLICKHOUSE_CLUSTER_NAME=langfuse. Checks:
#   schema     the migrations ran ON CLUSTER: engines of every table on every replica, the cluster as seen
#   r2         SIGKILL clickhouse-2 (a replica Langfuse does not talk to) at 35 s for 20 s: loss, catch-up time
#   r1         SIGKILL clickhouse (the replica in CLICKHOUSE_URL) the same way: loss, then 03c reconcile
#   lb-r1      CLICKHOUSE_URL=http://chlb:8123 (HAProxy over the three, haproxy-ch3.cfg), SIGKILL clickhouse
# Load as 03: 1,200 traces/min × 4 observations of 10 KB in + 1 KB out, one trace per POST, 150 s, SDK retry 5 s.
#   Usage: ./08-clickhouse-cluster.sh [step ...]   (default: schema r2 r1 lb-r1; KEEP=1 leaves the cluster up,
#          `down` alone only tears it down). Reconcile a run meanwhile:
#          OPS_PROJECT=langfuse-hols-v4ch3 RUNS_FILE=results/08-cluster.jsonl ./03c-reconcile.sh --replay <run_id>
# Writes results/08-cluster.txt, results/08-cluster.jsonl, results/08-<step>-samples.tsv.
set -euo pipefail
export OPS_PROJECT=langfuse-hols-v4ch3
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OUT="$RESULTS/08-cluster.jsonl"; TXT="$RESULTS/08-cluster.txt"
steps=("$@"); [[ ${#steps[@]} -eq 0 ]] && steps=(schema r2 r1 lb-r1)
C1="$LF_PROJECT-clickhouse-1"; C2="$LF_PROJECT-clickhouse-2-1"; C3="$LF_PROJECT-clickhouse-3-1"
LOAD=(--rpm 1200 --seconds 150 --obs 4 --prompt-bytes 10000 --output-bytes 1000 --traces-per-post 1 --retry-deadline 5)

c3() {
  local -a envs=(--env-file "$TRACK_DIR/versions.env")
  [[ -f "${LF_ENV_FILE:-$BASE_DIR/.env}" ]] && envs+=(--env-file "${LF_ENV_FILE:-$BASE_DIR/.env}")
  LF_TRACK="$TRACK" docker compose -p "$LF_PROJECT" "${envs[@]}" -f "$BASE_DIR/docker-compose.yml" \
    -f "$HERE/docker-compose.ch3.yml" "$@"
}
chq() { docker exec -i "$1" clickhouse-client -u "${CLICKHOUSE_USER:-clickhouse}" --password "${CLICKHOUSE_PASSWORD:-clickhouse}" -q "$2"; }
up() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | sed 's/true/up/; s/false/down/'; }
wait_lf() { local i; for i in $(seq 1 300); do
  curl -fsS -o /dev/null "$LANGFUSE_HOST/api/public/health" 2>/dev/null && curl -fsS -o /dev/null http://localhost:3030/api/health 2>/dev/null && return 0
  sleep 2; done; echo "✗ Langfuse not healthy after 600 s" >&2; return 1; }
log() { echo "$*" | tee -a "$TXT"; }

if [[ "$(up "$C1")" != up ]]; then
  log "== 08 cluster — $(date -u '+%Y-%m-%dT%H:%M:%SZ'): stopping the v4 stack (volumes kept), starting $LF_PROJECT"
  lf_compose -- stop >/dev/null 2>&1
  c3 up -d >/dev/null 2>&1 || { c3 ps; c3 logs --tail 40 langfuse-web; exit 1; }
  t_up=$(date +%s); wait_lf; log "  Langfuse healthy $(( $(date +%s) - t_up )) s after compose up (first start, migrations ON CLUSTER)"
fi

# rows of the run on one replica (blank while it is down)
rc() { chq "$1" "SELECT count() FROM events_full WHERE has(tags, '$run')" 2>/dev/null || echo ""; }
# replication queue of events_full on clickhouse-2 and its delay
rq() { chq "$C2" "SELECT queue_size, absolute_delay FROM system.replicas WHERE table = 'events_full' FORMAT TSV" 2>/dev/null || printf '?\t?'; }

for s in "${steps[@]}"; do
  case "$s" in
    schema)
      log "== schema ($(date -u '+%H:%M:%SZ')), Langfuse $(docker inspect -f '{{.Config.Image}}' "$LF_PROJECT-langfuse-web-1" | sed 's/.*://'), ClickHouse $(chq "$C1" 'SELECT version()')"
      log "  env: $(docker exec "$LF_PROJECT-langfuse-worker-1" sh -c 'env | grep -E "^CLICKHOUSE_(CLUSTER_ENABLED|CLUSTER_NAME|URL|MIGRATION_URL)=" | sort | tr "\n" " "')"
      log "  system.clusters on clickhouse: $(chq "$C1" "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters WHERE cluster = 'langfuse' FORMAT CSV" | tr '\n' ' ')"
      for c in "$C1" "$C2" "$C3"; do
        log "  ${c#$LF_PROJECT-}: $(chq "$c" "SELECT engine, count() FROM system.tables WHERE database = 'default' GROUP BY engine ORDER BY engine FORMAT CSV" | tr '\n' ' ')"
      done
      log "  schema_migrations: $(chq "$C1" "SELECT engine FROM system.tables WHERE database = 'default' AND name = 'schema_migrations'"), latest $(chq "$C1" "SELECT max(version) FROM schema_migrations"), dirty $(chq "$C1" "SELECT argMax(dirty, sequence) FROM schema_migrations")"
      log "  events_full: $(chq "$C1" "SELECT engine_full FROM system.tables WHERE database = 'default' AND name = 'events_full'" | cut -c1-200)"
      log "  replicas of events_full: $(chq "$C1" "SELECT replica_name, total_replicas, active_replicas FROM system.replicas WHERE table = 'events_full' FORMAT CSV")"
      continue ;;
    down) continue ;;   # nothing; the teardown below runs unless KEEP=1
    r2) kill="$C2" ;;
    r1|lb-r1) kill="$C1" ;;
    *) echo "unknown step $s" >&2; exit 2 ;;
  esac
  want=http://clickhouse:8123; [[ $s == lb-r1 ]] && want=http://chlb:8123
  have=$(docker exec "$LF_PROJECT-langfuse-worker-1" sh -c 'echo $CLICKHOUSE_URL')
  if [[ "$have" != "$want" ]]; then
    CH3_CLICKHOUSE_URL="$want" c3 up -d --no-deps --force-recreate langfuse-web langfuse-worker >/dev/null 2>&1
    wait_lf; sleep 5
  fi
  run="c-$s-$(date +%s)"
  samples="$RESULTS/08-$s-samples.tsv"
  printf 't_s\tch1\tch2\tch3\trows_ch1\trows_ch2\trows_ch3\tch2_queue\tch2_delay_s\n' > "$samples"
  ops_sample() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$(up "$C1")" "$(up "$C2")" "$(up "$C3")" "$(rc "$C1")" "$(rc "$C2")" "$(rc "$C3")" "$(rq)"; }
  log "▶ $s: CLICKHOUSE_URL=$want, kill ${kill#$LF_PROJECT-} at 35 s for 20 s (run $run)"
  export CH_CTR="$C3"   # count on a replica that stays up
  t0=$(date +%s)
  res=$(timeline_load "$run" "$samples" "35 docker kill $kill" "55 docker start $kill" -- "${LOAD[@]}")
  # catch-up: first sample after the restart in which the killed replica is within 100 rows (~1.25 s of ingest)
  # of a replica that stayed up (the two counts are read a moment apart while the load runs)
  started=$(jq -r '.events[1][1]' <<<"$res")
  col=5; [[ $kill == "$C2" ]] && col=6
  caught=$(awk -F'\t' -v st="$started" -v c="$col" 'NR > 1 && $1 >= st && $c != "" && $7 != "" && $c + 100 >= $7 {print $1 - st; exit}' "$samples")
  # where Langfuse's inserts went: initial INSERT queries per replica during the run
  hosts=$(for c in "$C1" "$C2" "$C3"; do
            n=$(chq "$c" "SYSTEM FLUSH LOGS; SELECT count() FROM system.query_log WHERE type = 'QueryFinish' AND query_kind = 'Insert' AND is_initial_query AND has(tables, 'default.events_full') AND event_time >= fromUnixTimestamp($t0)" 2>/dev/null | tail -1)
            printf '%s=%s ' "${c#$LF_PROJECT-}" "${n:-?}"; done)
  rows=$(for c in "$C1" "$C2" "$C3"; do printf '%s=%s ' "${c#$LF_PROJECT-}" "$(rc "$c")"; done)
  unset CH_CTR
  jq -c --arg s "$s" --arg u "$want" --arg k "${kill#$LF_PROJECT-}" --arg cu "${caught:-}" --arg h "$hosts" --arg r "$rows" \
     '{step: $s, clickhouse_url: $u, killed: $k} + . + {catch_up_s: (if $cu == "" then null else ($cu|tonumber) end),
      inserts_by_replica: $h, rows_by_replica_end: $r}' <<<"$res" | tee -a "$OUT" |
    jq -r '"  sent \(.sent_obs)  accepted \(.accepted_obs)  arrived \(.arrived_obs)  server loss \(.server_loss_obs)  client dropped \(.client_dropped_obs)  http \(.http)  catch-up \(.catch_up_s) s  inserts \(.inserts_by_replica)  rows \(.rows_by_replica_end)"' | tee -a "$TXT"
  log "  worker log: $(docker logs --since "$(( $(date +%s) - t0 + 5 ))s" "$LF_PROJECT-langfuse-worker-1" 2>&1 | grep -cE 'Max attempts reached' || true) × 'Max attempts reached'"
done

if [[ "${KEEP:-0}" != 1 ]]; then
  log "== removing $LF_PROJECT and its volumes, starting the v4 stack again"
  c3 down -v --remove-orphans >/dev/null 2>&1
  "$BASE_DIR/bin/up.sh" v4 >/dev/null
  OPS_PROJECT= LF_PROJECT=langfuse-hols-v4 wait_healthy
fi
