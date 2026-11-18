#!/usr/bin/env bash
# 05 — ClickHouse 25.2 -> 26.8 in place, under live v3 traffic; then v3.172.1 must still ingest and read.
# ClickHouse 26.8 changed input_format_read_datetime_number_as_raw_value from 1 to 0. Langfuse v3
# before 3.225.7 sends DateTime64 values as bare millisecond integers, which 26.8 now reads as
# seconds: every created_at/updated_at/event_ts it writes is 1000x too large (shown 9999-12-31;
# langfuse/langfuse#16858, fixed in 3.225.7). The first run of this lab hit it
# (results/05-ch-upgrade-without-setting.txt). So the new image starts with a users.d profile that
# sets it back to 1, in the same rollout. CH_DATETIME_FIX=0 reproduces the failure.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
url=$(pf app langfuse-app 3000); trap 'pf_stop app' EXIT
export LANGFUSE_HOST=$url LANGFUSE_PUBLIC_KEY=$LF_PK LANGFUSE_SECRET_KEY=$LF_SK

log "before"
ch -q "SELECT version()"
ch -q "SELECT message FROM system.warnings FORMAT TSV" | sed 's/^/warning: /'
ch -q "SELECT version, dirty FROM default.schema_migrations ORDER BY sequence DESC LIMIT 1"
before=$(ch -q "SELECT count() FROM default.traces FINAL")

log "traffic on (1 OTel trace/s to langfuse-app = v3) and a 0.5 s ClickHouse probe from inside the cluster"
./traffic.sh start ch-upgrade
kx -n "$NS" exec lab-curl -- sh -c 'rm -f /tmp/stop-probe; (while [ ! -f /tmp/stop-probe ]; do
  c=$(curl -s -m 1 -o /dev/null -w "%{http_code}" http://clickhouse:8123/ping); echo "$(date +%s) $c"; sleep 0.5; done) >/tmp/probe.log 2>&1 &'
sleep 15

log "upgrade: image $CH_START -> $CH_TARGET (StatefulSet rolling restart of the one replica)"
t0=$(now)
if [ "${CH_DATETIME_FIX:-1}" = 1 ]; then
  kx -n "$NS" patch configmap clickhouse-config --type merge -p '{"data":{"v3-datetime.xml":"<clickhouse><profiles><default><input_format_read_datetime_number_as_raw_value>1</input_format_read_datetime_number_as_raw_value></default></profiles></clickhouse>\n"}}'
  kx -n "$NS" patch statefulset clickhouse --type strategic -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"clickhouse\",
    \"image\":\"clickhouse/clickhouse-server:$CH_TARGET\",\"volumeMounts\":[{\"name\":\"config\",
    \"mountPath\":\"/etc/clickhouse-server/users.d/v3-datetime.xml\",\"subPath\":\"v3-datetime.xml\"}]}]}}}}"
else
  kx -n "$NS" set image statefulset/clickhouse clickhouse=clickhouse/clickhouse-server:"$CH_TARGET"
fi
kx -n "$NS" rollout status statefulset/clickhouse --timeout=600s
echo "rollout: $(elapsed "$t0") s"
sleep 60   # let the worker retry what failed during the restart
kx -n "$NS" exec lab-curl -- touch /tmp/stop-probe; sleep 1
kx -n "$NS" exec lab-curl -- cat /tmp/probe.log >"$WORK/ch-probe.log"
awk '$2 != 200 {if (!f) f=$1; l=$1; n++} END {printf "ClickHouse /ping not 200: %d probes, window %ds\n", n, (n ? l-f+1 : 0)}' "$WORK/ch-probe.log"
./traffic.sh stop "$WORK/traffic-ch-upgrade.log"
./traffic.sh report "$WORK/traffic-ch-upgrade.log"

log "after"
ch -q "SELECT version()"
ch -q "SELECT message FROM system.warnings FORMAT TSV" | sed 's/^/warning: /'
ch -q "SELECT version, dirty FROM default.schema_migrations ORDER BY sequence DESC LIMIT 1"
ch -q "SELECT name, value FROM system.settings WHERE changed FORMAT TSV" | sed 's/^/changed setting: /'
ch -q "SELECT name, value, default FROM system.settings WHERE name = 'input_format_read_datetime_number_as_raw_value' FORMAT TSV"
echo "v3 web/worker restarts: $(kx -n "$NS" get pods -l app.kubernetes.io/instance=$V3 -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount} {end}')"
kx -n "$NS" logs deploy/"$V3"-langfuse-worker --since=4m | grep -iE 'error' | grep -ioE '(ECONNREFUSED|socket hang up|Code: [0-9]+[^"]{0,80}|timeout[^"]{0,40})' | sort | uniq -c | sort -rn | head -8

log "every 2xx traffic trace of the upgrade window is in v3's ClickHouse"
ids=$(awk '$2 ~ /^20/ {printf "%s\x27%s\x27", (n++ ? "," : ""), $3}' "$WORK/traffic-ch-upgrade.log")
sent=$(awk '$2 ~ /^20/' "$WORK/traffic-ch-upgrade.log" | wc -l | tr -d ' ')
check "2xx traffic traces stored in default.traces" "$(ch -q "SELECT uniqExact(id) FROM default.traces WHERE id IN ($ids)")" "$sent"

log "v3.172.1 after the upgrade: ingest (SDK v3 + legacy API) and read"
"$PY" produce.py traces --phase after-ch-upgrade --n 10
"$PY" produce.py legacy-http --phase after-ch-upgrade --n 5
sleep 20
check "new traces of after-ch-upgrade in default.traces" \
  "$(ch -q "SELECT count() FROM default.traces FINAL WHERE has(tags, 'phase:after-ch-upgrade')")" 15
check "rows written after the upgrade with a DateTime64 after 2200 (traces, observations, scores)" \
  "$(ch -q "SELECT (SELECT count() FROM default.traces WHERE created_at > '2200-01-01' OR event_ts > '2200-01-01')
             + (SELECT count() FROM default.observations WHERE created_at > '2200-01-01' OR event_ts > '2200-01-01')
             + (SELECT count() FROM default.scores WHERE created_at > '2200-01-01' OR event_ts > '2200-01-01')")" 0
t=$(jq -r 'select(.phase=="v3-start" and (.producer|startswith("python-sdk"))) | .trace_id' "$WORK/sent.jsonl" | head -1)
check "GET /api/public/traces/<v3-start trace>" "$(api "$url" GET "/api/public/traces/$t")" 200
check "observations of that trace" "$(apij "$url" "/api/public/traces/$t" | jq '.observations | length')" 3
check "GET /api/public/observations" "$(api "$url" GET '/api/public/observations?limit=5')" 200
check "GET /api/public/scores" "$(api "$url" GET '/api/public/scores?limit=5')" 200
check "GET /api/public/metrics/daily" "$(api "$url" GET '/api/public/metrics/daily?limit=5')" 200
check "GET /api/public/sessions" "$(api "$url" GET '/api/public/sessions?limit=5')" 200
echo "traces in default.traces: before $before, after $(ch -q 'SELECT count() FROM default.traces FINAL')"
exit $fail
