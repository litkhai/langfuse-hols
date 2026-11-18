#!/usr/bin/env bash
# 10 — the cutover, under one OTel trace per second to langfuse-app:
#   1  delta copy while v3 serves, backfill re-run for the touched partitions
#   2  final Postgres copy: dump v3's database into a new database, v4 restarted on it
#      (v4 is not serving yet, so clients see nothing of it)
#   3  switch: the langfuse-app Service moves from v3 web to v4 web
#   4  v3 drains its queues; final delta copy; backfill re-run (the "read gap" ends here)
#   5  no-loss check: every 2xx trace is in v4
#   6  rollback rehearsal: back to v3 for 30 s, forward to v4 again, delta of that window
#   7  SDKs on v4: Python SDK 3.x and 4.x (OTel) accepted, the legacy ingestion API refused
#   8  v3 scaled to 0 (release, database and data kept for a later rollback)
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
T=$RES/cutover-timeline.txt; : >"$T"
mark() { printf '%s %s\n' "$(now)" "$*" | tee -a "$T"; }
to() { kx -n "$NS" patch service langfuse-app --type merge -p "{\"spec\":{\"selector\":{\"app.kubernetes.io/instance\":\"$1\",\"app\":\"web\"}}}" >/dev/null; }
# Partitions the next delta touches (event_ts after the watermark; see copy-ch.sh for the repair).
parts() { ch -q "SELECT arrayStringConcat(groupUniqArray(toString(toYYYYMM(timestamp))), ' ') FROM default.traces
  WHERE if(event_ts > toDateTime64('2200-01-01', 3), fromUnixTimestamp64Milli(intDiv(toUnixTimestamp64Milli(event_ts), 1000)), event_ts) > '$1'"; }
# v3's BullMQ jobs still waiting or running (v3 has no key prefix: bull:<queue>:...; v4's are lf-v4:...).
queues() { { rcli --scan --pattern 'bull:*' | grep -E ':(wait|active|prioritized)$' || true; } | while read -r k; do
  case $(rcli TYPE "$k") in list) rcli LLEN "$k";; zset) rcli ZCARD "$k";; *) echo 0;; esac; done | awk '{s+=$1} END {print s+0}'; }

./traffic.sh start cutover
mark "traffic on, langfuse-app -> $V3"
sleep 20

log "1 delta copy while v3 serves"
mark "delta-1 start"
wm=$(cat "$WORK/watermark"); p=$(parts "$wm")
./copy-ch.sh delta | tee -a "$T"
./rebackfill.sh $p | tail -2 | tee -a "$T"
mark "delta-1 done (partitions $p)"

log "2 final Postgres copy into langfuse_v4_cut; v4 restarted on it (not serving yet)"
mark "pg-final start"
psql_ postgres -c "DROP DATABASE IF EXISTS langfuse_v4_cut WITH (FORCE)" >/dev/null
psql_ postgres -c "CREATE DATABASE langfuse_v4_cut" >/dev/null
kx -n "$NS" exec pg-main-0 -- sh -c "PGPASSWORD=$PG_PW pg_dump -U postgres -Fc langfuse | PGPASSWORD=$PG_PW pg_restore -U postgres -d langfuse_v4_cut --no-owner"
mark "pg dump+restore done"
# The restored database brings the v4 backfill rows unfinished. Gate off while v4 migrates it, then
# mark the chain finished: langfuse_v4 already holds its result; only the delta is re-run (step 4).
v4env "DATABASE_URL=postgresql://postgres:$PG_PW@pg-main:5432/langfuse_v4_cut" "LANGFUSE_BACKGROUND_MIGRATION_V4_ENABLE_HISTORIC_BACKFILL=false"
restart "$V4"
psql_ langfuse_v4_cut -c "UPDATE background_migrations SET finished_at = now() WHERE name LIKE '20260701_v4_step_%' AND name NOT LIKE '%step_5%'" >/dev/null
v4env "LANGFUSE_BACKGROUND_MIGRATION_V4_ENABLE_HISTORIC_BACKFILL=true"
kx -n "$NS" rollout restart deploy/"$V4"-langfuse-worker >/dev/null; kx -n "$NS" rollout status deploy/"$V4"-langfuse-worker --timeout=600s >/dev/null
export PGDB=langfuse_v4_cut   # rebackfill.sh: the chain rows now live there
mark "pg-final done: v4 on langfuse_v4_cut"
v4url=$(pf v4 "$V4"-langfuse-web 3000)
check "v4 on the final Postgres copy: GET /api/public/projects" "$(api "$v4url" GET /api/public/projects)" 200

log "3 switch langfuse-app -> $V4"
mark "switch"
ts_switch=$(date +%s)
to "$V4"
kx -n "$NS" get endpointslices -l kubernetes.io/service-name=langfuse-app -o jsonpath='{.items[0].endpoints[*].addresses}'; echo

log "4 drain v3, final delta, backfill re-run"
for _ in $(seq 1 60); do q=$(queues); [ "$q" = 0 ] && break; sleep 2; done
mark "v3 queues drained (wait+active+prioritized = $q)"
sleep 10   # the worker's ClickHouse write interval
wm=$(cat "$WORK/watermark"); p=$(parts "$wm")
./copy-ch.sh delta | tee -a "$T"
./rebackfill.sh $p | tail -2 | tee -a "$T"
mark "read gap closed (final delta in events_full)"

log "5 no-loss check"
sleep 20
./traffic.sh stop "$WORK/traffic-cutover-a.log" >/dev/null; ./traffic.sh start cutover-b
ids=$(awk '$2 ~ /^20/ {printf "%s\x27%s\x27", (n++ ? "," : ""), $3}' "$WORK/traffic-cutover-a.log")
ok=$(awk '$2 ~ /^20/' "$WORK/traffic-cutover-a.log" | wc -l | tr -d ' ')
./traffic.sh report "$WORK/traffic-cutover-a.log" | tee -a "$T"
check "2xx traffic traces in v4 events_full" "$(ch -q "SELECT uniqExact(trace_id) FROM langfuse_v4.events_full WHERE trace_id IN ($ids)")" "$ok"
in_v3=$(ch -q "SELECT uniqExact(id) FROM default.traces WHERE id IN ($ids)")
echo "of them served by v3 (in default.traces): $in_v3, by v4 directly: $(( ok - in_v3 ))" | tee -a "$T"
last_v3=$(ch -q "SELECT max(timestamp) FROM default.traces WHERE id IN ($ids)")
first_v4=$(ch -q "SELECT min(start_time) FROM langfuse_v4.events_full WHERE trace_id IN ($ids) AND trace_id NOT IN (SELECT id FROM default.traces)")
echo "last trace served by v3: $last_v3, first served by v4: $first_v4 (switch at $(date -u -r "$ts_switch" '+%F %T'))" | tee -a "$T"
check "v3 traces missing from v4 events_full" \
  "$(ch -q 'SELECT count() FROM (SELECT id FROM default.traces FINAL) t LEFT ANTI JOIN (SELECT DISTINCT trace_id FROM langfuse_v4.events_full) e ON t.id = e.trace_id')" 0
check "v3 observations missing from v4 events_full" \
  "$(ch -q 'SELECT count() FROM (SELECT id FROM default.observations FINAL) o LEFT ANTI JOIN (SELECT span_id FROM langfuse_v4.events_full) e ON o.id = e.span_id')" 0
check "v3 scores missing from v4" \
  "$(ch -q 'SELECT count() FROM (SELECT id FROM default.scores FINAL) s LEFT ANTI JOIN (SELECT id FROM langfuse_v4.scores) e ON s.id = e.id')" 0

log "6 rollback rehearsal: langfuse-app -> $V3 for 30 s, then -> $V4 again"
mark "rollback to v3"; to "$V3"; sleep 30
mark "forward to v4"; to "$V4"
for _ in $(seq 1 60); do [ "$(queues)" = 0 ] && break; sleep 2; done; sleep 10
wm=$(cat "$WORK/watermark"); p=$(parts "$wm")
./copy-ch.sh delta | tee -a "$T"
./rebackfill.sh $p | tail -2 | tee -a "$T"
mark "rollback window copied"
sleep 20
./traffic.sh stop "$WORK/traffic-cutover-b.log" >/dev/null
./traffic.sh report "$WORK/traffic-cutover-b.log" | tee -a "$T"
ids=$(awk '$2 ~ /^20/ {printf "%s\x27%s\x27", (n++ ? "," : ""), $3}' "$WORK/traffic-cutover-b.log")
ok=$(awk '$2 ~ /^20/' "$WORK/traffic-cutover-b.log" | wc -l | tr -d ' ')
check "2xx traffic traces of the rollback run in v4 events_full" "$(ch -q "SELECT uniqExact(trace_id) FROM langfuse_v4.events_full WHERE trace_id IN ($ids)")" "$ok"
echo "of them served by v3 during the rollback window: $(ch -q "SELECT uniqExact(id) FROM default.traces WHERE id IN ($ids)")" | tee -a "$T"

log "7 SDKs and APIs through langfuse-app (now v4)"
url=$(pf app langfuse-app 3000); trap 'pf_stop app; pf_stop v4' EXIT
export LANGFUSE_HOST=$url LANGFUSE_PUBLIC_KEY=$LF_PK LANGFUSE_SECRET_KEY=$LF_SK
"$PY"  produce.py traces --phase v4-after-cutover --n 5
"$PY4" produce.py traces --phase v4-after-cutover --n 5
"$PY"  produce.py legacy-http --phase v4-after-cutover --n 2 || true
sleep 30
for prod in python-sdk-3.15.0 python-sdk-4.17.0 legacy-http; do
  ids=$(jq -r "select(.phase==\"v4-after-cutover\" and .producer==\"$prod\") | .trace_id" "$WORK/sent.jsonl" | sed "s/.*/'&'/" | paste -sd, -)
  echo "$prod: $(ch -q "SELECT uniqExact(trace_id) FROM langfuse_v4.events_full WHERE trace_id IN (${ids:-''})") traces in v4 events_full"
done
code=$(curl -s -u "$LF_PK:$LF_SK" -H 'Content-Type: application/json' -X POST "$url/api/public/ingestion" \
  -d '{"batch":[{"id":"e1","type":"trace-create","timestamp":"2026-11-18T00:00:00.000Z","body":{"id":"cutover-probe"}}]}')
echo "POST /api/public/ingestion trace-create on v4: $(echo "$code" | jq -c '{successes: (.successes|length), errors: [.errors[] | {status, message: (.message|.[0:80])}]}')"
for ep in "GET /api/public/traces" "GET /api/public/observations" "GET /api/public/v2/observations" "GET /api/public/v3/scores" "GET /api/public/metrics/daily"; do
  set -- $ep; echo "$ep -> $(api "$url" "$1" "$2?limit=1")"
done

log "8 v3 down (scaled to 0; release, Postgres database and ClickHouse database kept)"
kx -n "$NS" scale deploy/"$V3"-langfuse-web deploy/"$V3"-langfuse-worker --replicas=0 >/dev/null
mark "v3 scaled to 0"
check "health through langfuse-app with v3 down" "$(curl -s "$url/api/public/health" | jq -r .version)" "$LF_V4"
log "timeline"; cat "$T"
exit $fail
