#!/usr/bin/env bash
# 02-sizing.sh — the highest sustained ingest rate whose lag (events_full.created_at − span start) stays ≤ 2 s.
#
# Three set-ups, each on the shared v4 stack (Docker Desktop on one laptop — read the ratios, not the numbers):
#   w1        one worker, no CPU cap
#   w1-cpu2   web and worker capped at 2 CPUs each (overlay cpu2)        → maps to pod requests cpu: "2"
#   w2-cpu2   web + two workers, each capped at 2 CPUs (overlays cpu2 worker2 cpu2w2)
# Per set-up a ladder of rates (traces/min), 4 observations per trace, 10 KB in + 1 KB out per observation,
# TPP traces per OTLP POST (default 1), 60 s per step. A step passes when lag p95 ≤ 2 s, nothing is lost and the sender
# kept up (≤ 1 s behind). The ladder stops at the first failing step. Each set-up starts with a 20 s warm-up
# load that is not measured; each step records the CPU % of containers outside this stack. Then one read-mix step at the best
# rate of w1-cpu2 with READ_RATIO reads per trace (trace detail and observations list, alternating).
#   Usage: ./02-sizing.sh [setup ...]   (default: w1 w1-cpu2 w2-cpu2 read)
#   Env:   SECS=60 READ_RATIO=0.1 TPP=1 LADDER="2000 4000 …" OUT=results/02-sizing.jsonl
# Writes results/02-sizing.jsonl. Ends on the normal OSS stack.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SECS="${SECS:-60}"
READ_RATIO="${READ_RATIO:-0.1}"
TPP="${TPP:-1}"   # traces per OTLP POST (1 = worst case for web; an SDK batches up to flush_at spans)
LADDER=(${LADDER:-2000 4000 8000 12000 16000 20000 24000 30000})
OUT="${OUT:-$RESULTS/02-sizing.jsonl}"
setups=("$@"); [[ ${#setups[@]} -eq 0 ]] && setups=(w1 w1-cpu2 w2-cpu2 read)

overlays() { case "$1" in w1) echo "";; w1-cpu2|read) echo "cpu2";; w2-cpu2) echo "cpu2 worker2 cpu2w2";; esac; }

# CPU % used by containers that are not this stack (other work on the same Docker VM skews timings)
foreign_cpu() {
  docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' |
    awk -v p="$LF_PROJECT-" 'index($1, p) != 1 {gsub("%", "", $2); s += $2} END {printf "%.0f", s}'
}

# CPU % of this stack's web and worker(s), sampled once in the middle of a step
stack_cpu() {
  docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' |
    awk -v p="$LF_PROJECT-" 'index($1, p) == 1 && $1 ~ /langfuse-(web|worker)/ {gsub("%", "", $2); sub(p, "", $1); sub("-1$", "", $1); printf "%s%s=%.0f", sep, $1, $2; sep=" "}'
}

step() {   # step <setup> <rpm> [read ratio]
  local s="$1" rpm="$2" rr="${3:-0}" fc cpuf
  fc=$(foreign_cpu)
  cpuf="$(mktemp)"
  ( sleep $(( ${SECS%.*} / 2 )); stack_cpu > "$cpuf" ) &
  local res
  res=$(run_load "s-$s-$rpm-$(date +%s)" --rpm "$rpm" --seconds "$SECS" --read-ratio "$rr" --threads 128 \
                 --traces-per-post "$TPP")
  wait
  jq -c --arg s "$s" --argjson fc "$fc" --arg cpu "$(cat "$cpuf")" '{setup: $s, foreign_cpu_pct: $fc, stack_cpu_pct: $cpu, pass: (.lag_p95_s <= 2 and .loss_obs == 0 and .sender_behind_s <= 1)} + .' <<<"$res" |
    tee -a "$OUT" |
    jq -r '"  \(.setup) \(.rpm) rpm, \(.traces_per_post)/POST: \(if .pass then "PASS" else "FAIL" end)  CPU % \(.stack_cpu_pct), other containers \(.foreign_cpu_pct)  lag p50/p95/p99/max \(.lag_p50_s)/\(.lag_p95_s)/\(.lag_p99_s)/\(.lag_max_s) s  loss \(.loss_obs)  behind \(.sender_behind_s) s  accept p95 \(.accept_p95_ms) ms  reads \(.reads_ok // 0) p95 \(.read_p95_ms) ms"'
}

best_cpu2=""
for s in "${setups[@]}"; do
  echo "▶ $s"
  # shellcheck disable=SC2046
  ops_apply $(overlays "$s")
  "$PY" "$HERE/loadgen.py" --run-id "warmup-$s-$(date +%s)" --rpm 1200 --seconds 20 >/dev/null   # not measured
  sleep 10
  if [[ "$s" == read ]]; then
    best_cpu2="${best_cpu2:-$(jq -s -r '[.[] | select(.setup == "w1-cpu2" and .pass)] | max_by(.rpm) | .rpm // 4000' "$OUT")}"
    step read "$best_cpu2" 0
    step read "$best_cpu2" "$READ_RATIO"
    continue
  fi
  for rpm in "${LADDER[@]}"; do
    step "$s" "$rpm"
    pass=$(tail -1 "$OUT" | jq -r .pass)
    [[ "$s" == w1-cpu2 && "$pass" == true ]] && best_cpu2="$rpm"
    [[ "$pass" == true ]] || break
  done
done
echo "▶ restoring the normal OSS stack"
ops_restore
