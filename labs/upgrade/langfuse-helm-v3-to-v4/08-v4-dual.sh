#!/usr/bin/env bash
# 08 — `dual`: every write lands in the old tables and in events_full. SDK v4 (>= 4.7.0) writes
# events_full directly; SDK v3 and the legacy API go through the staging table and the
# propagation job, so they show up in events_full later (the guide says ~15 minutes).
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1: $2"; else echo "FAIL  $1: expected $3, got $2"; fail=1; fi; }
in_events() {  # in_events <phase> <producer-prefix>: sent traces of that producer with a root row in events_full
  local ids; ids=$(jq -r --arg p "$1" --arg q "$2" 'select(.phase==$p and (.producer|startswith($q))) | .trace_id' "$WORK/sent.jsonl" | sed "s/.*/'&'/" | paste -sd, -)
  v2_ch -q "SELECT uniqExact(trace_id) FROM events_full WHERE trace_id IN ($ids)"
}

log "write mode dual"
setmode dual
url=$(pf app langfuse-app 3000); trap 'pf_stop app' EXIT
export LANGFUSE_HOST=$url LANGFUSE_PUBLIC_KEY=$LF_PK LANGFUSE_SECRET_KEY=$LF_SK
before_old=$(v2_ch -q "SELECT count() FROM traces FINAL")

t0=$(date +%s)
"$PY"  produce.py traces --phase v4-dual --n 10
"$PY4" produce.py traces --phase v4-dual --n 10
"$PY"  produce.py legacy-http --phase v4-dual --n 5
sleep 20

log "right after the writes"
check "new rows in traces (old table)" "$(( $(v2_ch -q 'SELECT count() FROM traces FINAL') - before_old ))" 25
check "SDK v4 traces in events_full" "$(in_events v4-dual python-sdk-4)" 10
echo "SDK v3 traces in events_full: $(in_events v4-dual python-sdk-3)/10 · legacy API: $(in_events v4-dual legacy-http)/5"
echo "staging rows: $(v2_ch -q 'SELECT count() FROM observations_batch_staging')"

log "wait for the propagation job (up to 30 min)"
for _ in $(seq 1 180); do
  a=$(in_events v4-dual python-sdk-3); b=$(in_events v4-dual legacy-http)
  [ "$a" = 10 ] && [ "$b" = 5 ] && break
  sleep 10
done
echo "propagated after $(( $(date +%s) - t0 ))s"
check "SDK v3 traces in events_full" "$(in_events v4-dual python-sdk-3)" 10
check "legacy API traces in events_full" "$(in_events v4-dual legacy-http)" 5

log "both read paths on dual"
check "GET /api/public/traces (v3 read path)" "$(api GET '/api/public/traces?limit=1')" 200
check "GET /api/public/v2/observations (v4 read path)" "$(api GET '/api/public/v2/observations?limit=1')" 200
echo "pre-dual traces in events_full (no backfill yet): $(in_events v3-start python-sdk-3)/40"
kx -n "$NS" exec deploy/"$V2"-worker -- wget -qO- "http://localhost:3030/api/health?failIfQueueConsumptionStuck=true&failIfEventPropagationStuck=true"; echo
exit $fail
