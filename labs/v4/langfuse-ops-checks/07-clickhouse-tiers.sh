#!/usr/bin/env bash
# 07-clickhouse-tiers.sh — what ClickHouse itself uses at 1,000 / 2,000 / 4,000 traces/min (the small, medium,
# large tiers), to check the proposed ClickHouse sizes instead of guessing them.
#
# Per step: RATE traces/min × 4 observations (10 KB in + 1 KB out each), 10 traces per OTLP POST (as 02 passed),
# 0.1 reads per trace (trace detail and observations list, alternating), SECS seconds, web + worker at 2 CPUs
# (overlay cpu2, as 02). Before the ladder: IDLE seconds without load (ClickHouse's own background work and
# Langfuse's jobs). Measured on the ClickHouse container only:
#   cpu_s_per_min     cgroup cpu.stat usage_usec over [load start, rows settled + 20 s], per minute of load
#   mem_peak          max of cgroup memory.current, anon (memory.stat) and ClickHouse MemoryTracking, sampled 2 s
#   inserts           INSERT queries finished (all tables) and parts written (system.part_log NewPart) per second
#   merges            MergeParts events in system.part_log, max merges running, max active parts of events_full
#   disk              growth of active parts' bytes_on_disk in database default, per hour and per day of load
#   read p95          from the generator; lag and loss as in 02 (lib.sh measure)
#   foreign CPU       CPU % of containers outside this stack at the start of the step (as 02)
#   Usage: ./07-clickhouse-tiers.sh   Env: RATES="1000 2000 4000" SECS=240 IDLE=60 READ_RATIO=0.1 TPP=10
# Writes results/07-clickhouse-tiers.jsonl and results/07-<rate>-samples.tsv. Ends on the normal OSS stack.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
RATES=(${RATES:-1000 2000 4000}); SECS="${SECS:-240}"; IDLE="${IDLE:-60}"
READ_RATIO="${READ_RATIO:-0.1}"; TPP="${TPP:-10}"
OUT="$RESULTS/07-clickhouse-tiers.jsonl"
CHC="$LF_PROJECT-clickhouse-1"

cg() { docker exec "$CHC" sh -c "cat /sys/fs/cgroup/$1"; }
cpu_us() { cg cpu.stat | awk '$1 == "usage_usec" {print $2}'; }
disk_b() { ch "SELECT sum(bytes_on_disk) FROM system.parts WHERE active AND database = 'default'"; }
foreign_cpu() {
  docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' |
    awk -v p="$LF_PROJECT-" 'index($1, p) != 1 {gsub("%", "", $2); s += $2} END {printf "%.0f", s}'
}
sampler() {   # sampler <file> — every 2 s until killed
  printf 't_unix\tmem_current\tanon\tmemory_tracking\tparts_events_full\tmerges_running\n' > "$1"
  while :; do
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$(cg memory.current)" "$(cg memory.stat | awk '$1 == "anon" {print $2}')" \
      "$(ch "SELECT (SELECT value FROM system.metrics WHERE metric = 'MemoryTracking'),
                    (SELECT count() FROM system.parts WHERE active AND database = 'default' AND table = 'events_full'),
                    (SELECT count() FROM system.merges) FORMAT TSV" 2>/dev/null)" >> "$1"
    sleep 2
  done
}
window() {   # window <from_unix> <to_unix> — inserts, parts written, merges in [from, to)
  ch "SYSTEM FLUSH LOGS" >/dev/null
  ch "SELECT
        (SELECT count() FROM system.query_log WHERE type = 'QueryFinish' AND query_kind = 'Insert'
           AND event_time >= fromUnixTimestamp($1) AND event_time < fromUnixTimestamp($2)),
        (SELECT count() FROM system.part_log WHERE event_type = 'NewPart' AND database = 'default'
           AND event_time >= fromUnixTimestamp($1) AND event_time < fromUnixTimestamp($2)),
        (SELECT count() FROM system.part_log WHERE event_type = 'MergeParts' AND database = 'default'
           AND event_time >= fromUnixTimestamp($1) AND event_time < fromUnixTimestamp($2))
      FORMAT JSONCompactEachRow"
}
peaks() {   # peaks <samples> — max mem_current, anon, MemoryTracking, parts, merges
  awk -F'\t' 'NR > 1 && NF >= 6 {for (i = 2; i <= 6; i++) if ($i + 0 > m[i]) m[i] = $i + 0}
    END {printf "[%d,%d,%d,%d,%d]", m[2], m[3], m[4], m[5], m[6]}' "$1"
}

echo "▶ web + worker at 2 CPUs (overlay cpu2); idle ${IDLE} s"
ops_apply cpu2
"$PY" "$HERE/loadgen.py" --run-id "warmup-07-$(date +%s)" --rpm 1200 --seconds 20 --traces-per-post "$TPP" >/dev/null
sleep 20
fc=$(foreign_cpu); smp="$RESULTS/07-idle-samples.tsv"; sampler "$smp" & sp=$!
c0=$(cpu_us); d0=$(disk_b); t0=$(date +%s)
sleep "$IDLE"
c1=$(cpu_us); d1=$(disk_b); t1=$(date +%s); kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null || true
w=$(window "$t0" "$t1")
idle_cpm=$(awk -v c="$(( c1 - c0 ))" -v s="$(( t1 - t0 ))" 'BEGIN {printf "%.2f", c / 1e6 / s * 60}')
jq -nc --argjson fc "$fc" --argjson s "$(( t1 - t0 ))" --argjson cpm "$idle_cpm" --argjson w "$w" --argjson pk "$(peaks "$smp")" \
   --argjson dd "$(( d1 - d0 ))" '{step: "idle", rpm: 0, seconds: $s, foreign_cpu_pct: $fc, ch_cpu_s_per_min: $cpm,
     ch_mem_current_max: $pk[0], ch_anon_max: $pk[1], ch_memory_tracking_max: $pk[2], parts_events_full_max: $pk[3],
     merges_running_max: $pk[4], inserts: $w[0], parts_written: $w[1], merges: $w[2], disk_delta_bytes: $dd}' | tee -a "$OUT"

for rate in "${RATES[@]}"; do
  echo "▶ $rate traces/min, $TPP per POST, $READ_RATIO reads per trace, ${SECS} s"
  fc=$(foreign_cpu); smp="$RESULTS/07-$rate-samples.tsv"; sampler "$smp" & sp=$!
  c0=$(cpu_us); d0=$(disk_b); t0=$(date +%s)
  res=$(run_load "t-$rate-$(date +%s)" --rpm "$rate" --seconds "$SECS" --traces-per-post "$TPP" \
          --read-ratio "$READ_RATIO" --threads 128)
  sleep 20   # merges triggered by the step's last parts
  c1=$(cpu_us); d1=$(disk_b); t1=$(date +%s); kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null || true
  w=$(window "$t0" "$t1")
  jq -c --arg st "$rate" --argjson fc "$fc" --argjson cu "$(( c1 - c0 ))" --argjson win "$(( t1 - t0 ))" \
        --argjson idle "$idle_cpm" --argjson w "$w" --argjson pk "$(peaks "$smp")" --argjson dd "$(( d1 - d0 ))" '
    {step: $st, foreign_cpu_pct: $fc, window_s: $win,
     ch_cpu_s_per_min: (($cu / 1e6 / .seconds * 60 * 100 | round) / 100),
     ch_cpu_s_per_min_net_of_idle: ((($cu / 1e6 - $idle * $win / 60) / .seconds * 60 * 100 | round) / 100),
     ch_mem_current_max: $pk[0], ch_anon_max: $pk[1], ch_memory_tracking_max: $pk[2], parts_events_full_max: $pk[3],
     merges_running_max: $pk[4], ch_insert_queries: $w[0], ch_insert_queries_per_s: (($w[0] / .seconds * 10 | round) / 10),
     parts_written: $w[1], parts_written_per_s: (($w[1] / .seconds * 10 | round) / 10), merges: $w[2],
     disk_delta_bytes: $dd, disk_per_hour_gib: (($dd / .seconds * 3600 / 1073741824 * 100 | round) / 100),
     disk_per_day_gib: (($dd / .seconds * 86400 / 1073741824 * 10 | round) / 10),
     disk_bytes_per_obs: (if .arrived_obs > 0 then ($dd / .arrived_obs | round) else null end)} + .' <<<"$res" |
    tee -a "$OUT" |
    jq -r '"  CH \(.ch_cpu_s_per_min) CPU-s/min (net \(.ch_cpu_s_per_min_net_of_idle)), mem max \(.ch_mem_current_max / 1048576 | round) MiB (anon \(.ch_anon_max / 1048576 | round), tracked \(.ch_memory_tracking_max / 1048576 | round)), inserts \(.ch_insert_queries_per_s)/s, parts \(.parts_written_per_s)/s, merges \(.merges), parts max \(.parts_events_full_max), disk \(.disk_per_hour_gib) GiB/h (\(.disk_bytes_per_obs) B/obs)  lag p95 \(.lag_p95_s) s  loss \(.loss_obs)  read p95 \(.read_p95_ms) ms  other CPU \(.foreign_cpu_pct) %"'
done
echo "▶ restoring the normal OSS stack"
ops_restore
