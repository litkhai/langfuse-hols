#!/usr/bin/env bash
# 11 — the cutover to events_only (the v4 defaults). The point of commitment.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1: $2"; else echo "FAIL  $1: expected $3, got $2"; fail=1; fi; }

log "write mode events_only"
setmode events_only
url=$(pf app langfuse-app 3000); trap 'pf_stop app' EXIT
export LANGFUSE_HOST=$url LANGFUSE_PUBLIC_KEY=$LF_PK LANGFUSE_SECRET_KEY=$LF_SK
before_old=$(v2_ch -q "SELECT count() FROM traces FINAL")
before_ev=$(v2_ch -q "SELECT uniqExact(trace_id) FROM events_full")

log "producers"
"$PY4" produce.py traces --phase v4-events-only --n 10
"$PY"  produce.py traces --phase v4-events-only --n 10 || true
"$PY"  produce.py legacy-http --phase v4-events-only --n 3 || true
sleep 30
check "new rows in traces (old table)" "$(( $(v2_ch -q 'SELECT count() FROM traces FINAL') - before_old ))" 0
echo "new traces in events_full: $(( $(v2_ch -q 'SELECT uniqExact(trace_id) FROM events_full') - before_ev ))"
ids=$(jq -r 'select(.phase=="v4-events-only" and (.producer|startswith("python-sdk-3"))) | .trace_id' "$WORK/sent.jsonl" | sed "s/.*/'&'/" | paste -sd, -)
echo "SDK v3 traces of this phase in events_full: $(v2_ch -q "SELECT uniqExact(trace_id) FROM events_full WHERE trace_id IN (${ids:-''})")/10"
kx -n "$NS" logs deploy/"$V2"-web --since=2m | grep -i -m3 -E "reject|unsupported|sdk version|ingestion version" || true

log "deprecated endpoints (upgrade guide, API changes)"
for ep in "GET /api/public/traces" "GET /api/public/observations" "GET /api/public/sessions" \
          "GET /api/public/scores" "GET /api/public/v2/scores" "GET /api/public/metrics/daily" \
          "GET /api/public/dataset-run-items" "GET /api/public/datasets/support-golden/runs"; do
  set -- $ep; echo "$ep -> $(api "$1" "$2")"
done
for ep in traces spans generations events; do echo "POST /api/public/$ep -> $(api POST /api/public/$ep '{}')"; done
code=$(curl -s -u "$LF_PK:$LF_SK" -H 'Content-Type: application/json' -X POST "$url/api/public/ingestion" \
  -d '{"batch":[{"id":"e1","type":"trace-create","timestamp":"2026-11-03T00:00:00.000Z","body":{"id":"cutover-probe"}}]}')
echo "POST /api/public/ingestion trace-create -> $code"

log "the replacements"
t=$(jq -r 'select(.phase=="v3-start" and (.producer|startswith("python-sdk-3"))) | .trace_id' "$WORK/sent.jsonl" | head -1)
check "GET /api/public/v2/observations?traceId=<v3-era trace>" "$(api GET "/api/public/v2/observations?traceId=$t")" 200
curl -s -u "$LF_PK:$LF_SK" "$url/api/public/v2/observations?traceId=$t" | jq -c '[.data[] | {name, type}]'
check "GET /api/public/v3/scores (Scores API v3)" "$(api GET '/api/public/v3/scores?limit=1')" 200
check "GET /api/public/experiments (fromStartTime is required)" "$(api GET '/api/public/experiments?fromStartTime=2026-11-01T00:00:00Z')" 200
curl -s -u "$LF_PK:$LF_SK" "$url/api/public/experiments?fromStartTime=2026-11-01T00:00:00Z" | jq -c '[.data[] | {name, datasetId: (.datasetId // .dataset_id)}]'
check "GET /api/public/v2/metrics" "$(api GET '/api/public/v2/metrics?query=%7B%22view%22%3A%22observations%22%2C%22metrics%22%3A%5B%7B%22measure%22%3A%22count%22%2C%22aggregation%22%3A%22count%22%7D%5D%2C%22fromTimestamp%22%3A%222026-11-01T00%3A00%3A00Z%22%2C%22toTimestamp%22%3A%222026-11-30T00%3A00%3A00Z%22%7D')" 200
kx -n "$NS" exec deploy/"$V2"-worker -- wget -qO- "http://localhost:3030/api/health?failIfQueueConsumptionStuck=true&failIfEventPropagationStuck=true"; echo
exit $fail
