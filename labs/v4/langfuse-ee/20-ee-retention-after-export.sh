#!/usr/bin/env bash
# 20-ee-retention-after-export.sh — archive-then-delete, run for real: does the Parquet archive outlive
# a retention deletion, and what happens to a span the export never picked up?
#
#   - a project with a 3-day retention (the minimum above 0) gets 5 spans 4 days old and 1 span 1 hour old;
#   - a scheduled Parquet export (weekly, FULL_HISTORY) archives all 6 (positive);
#   - then a LATE span arrives, also 4 days old: start_time is before last_sync_at, so step 19 says
#     no later export will take it;
#   - the worker restarts with the batch retention cleaner on a 1-minute interval (overlay `retention`):
#     the old spans leave ClickHouse, the 1-hour span stays (control: the cleaner does not over-delete);
#   - the archived old spans are still readable from Parquet (archive outlives deletion), and the late
#     span is in neither ClickHouse nor the archive: lost.
#
# The batch cleaner is off by default; the daily job ("15 3 * * *") is the default path. Both delete by
# start_time (Langfuse v4.56.0 worker/src/features/batch-data-retention-cleaner/index.ts,
# TIMESTAMP_COLUMN_MAP events_full: start_time). The worker is restored without the overlay on exit.
#
# Requires: stack up + EE (05), jq, openssl, ADMIN_API_KEY in _base/.env.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

for c in jq openssl curl; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
ADMIN="Authorization: Bearer ${ADMIN_API_KEY:?set ADMIN_API_KEY in _base/.env}"
BUCKET="${LANGFUSE_S3_BATCH_EXPORT_BUCKET:-langfuse}"
MK_USER="${MINIO_ROOT_USER:-minio}"; MK_PASS="${MINIO_ROOT_PASSWORD:-miniosecret}"
TS=$(date +%Y%m%d%H%M%S)
PREFIX="exports/lab20-$TS/"
S3="http://minio:9000/$BUCKET"
WORK=$(mktemp -d); chmod 700 "$WORK"
RESTORE=0
cleanup() {
  rm -rf "$WORK"
  if [ $RESTORE = 1 ]; then
    echo "════ Worker back without the retention overlay ════"
    lf_compose ee -- up -d langfuse-worker >/dev/null 2>&1 || true
    echo "  LANGFUSE_BATCH_DATA_RETENTION_CLEANER_ENABLED in worker: $( { lf_compose -- exec -T langfuse-worker printenv LANGFUSE_BATCH_DATA_RETENTION_CLEANER_ENABLED 2>/dev/null || true; } | tr -d '\r' )(empty = default false)"
  fi
}
trap cleanup EXIT

ROWS="$WORK/rows.tsv"; : > "$ROWS"; FAILS=0
row() {
  local res=PASS; [ "$5" = 1 ] || { res=FAIL; FAILS=$((FAILS+1)); }
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$res" >> "$ROWS"
  echo "  $res  $1 | $2 | expected: $3 | observed: $4"
}
g() { local n="$1_$2"; echo "${!n}"; }
PSQL=(lf_compose -- exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -P pager=off)
CH=(lf_compose -- exec -T clickhouse clickhouse-client -u "${CLICKHOUSE_USER:-clickhouse}" --password "${CLICKHOUSE_PASSWORD:-clickhouse}")
now_s() { date +%s; }

echo "════ 1. Organization, project with retention = 3 days, key, one ADMIN user ════"
ORG_ID=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations" -H "$ADMIN" -H "Content-Type: application/json" \
  -d "{\"name\":\"retention-$TS\"}" | jq -r .id)
ORG_KEY=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations/$ORG_ID/apiKeys" -H "$ADMIN" \
  -H "Content-Type: application/json" -d '{"note":"retention test"}')
ORG_AUTH="$(echo "$ORG_KEY" | jq -r .publicKey):$(echo "$ORG_KEY" | jq -r .secretKey)"
orgcurl() { curl -fsS -m 30 -u "$ORG_AUTH" "$@"; }
body="{\"name\":\"retention-$TS\",\"retention\":3}"   # a variable: bash 3.2 brace-expands a JSON literal inside "$( … )"
PID=$(orgcurl -X POST "$HOST/api/public/projects" -H "Content-Type: application/json" -d "$body" | jq -r .id)
K=$(orgcurl -X POST "$HOST/api/public/projects/$PID/apiKeys" -H "Content-Type: application/json" -d '{"note":"ingest"}')
PAUTH="$(echo "$K" | jq -r .publicKey):$(echo "$K" | jq -r .secretKey)"
rd=$("${PSQL[@]}" -tAc "SELECT coalesce(retention_days::text,'null') FROM projects WHERE id='$PID';" | tr -d '[:space:]')
[ "$rd" = 3 ] && ok=1 || ok=0; row project "retention_days in Postgres" "3" "$rd" $ok

EMAIL="expadmin-$TS@retention.test"
printf 'Aa1!%s' "$(openssl rand -hex 12)" > "$WORK/pw"
jq -n --arg e "$EMAIL" --rawfile p "$WORK/pw" '{name:"Retention admin",email:$e,password:$p}' \
  | curl -fsS -m 30 -X POST "$HOST/api/auth/signup" -H "Content-Type: application/json" -d @- >/dev/null
login() {
  local jar="$WORK/jar"; : > "$jar"
  local csrf; csrf=$(curl -fsS -m 30 -c "$jar" -b "$jar" "$HOST/api/auth/csrf" | jq -r .csrfToken)
  curl -sS -m 30 -c "$jar" -b "$jar" -o /dev/null -X POST "$HOST/api/auth/callback/credentials" \
    --data-urlencode "csrfToken=$csrf" --data-urlencode "email=$EMAIL" \
    --data-urlencode "password@$WORK/pw" --data-urlencode "callbackUrl=$HOST/" --data-urlencode "json=true"
  curl -fsS -m 30 -b "$jar" -c "$jar" "$HOST/api/auth/session"
}
U=$(login | jq -r '.user.id // empty')
orgcurl -X PUT "$HOST/api/public/organizations/memberships" -H "Content-Type: application/json" \
  -d "{\"userId\":\"$U\",\"role\":\"ADMIN\"}" >/dev/null
login >/dev/null
run_now() {
  curl -sS -m 60 -b "$WORK/jar" -o /dev/null -w '%{http_code}' -X POST "$HOST/api/trpc/blobStorageIntegration.runNow" \
    -H "Content-Type: application/json" -d "{\"json\":{\"projectId\":\"$PID\"}}"
}

span() {  # span <trace id> <name> <start epoch seconds>
  local ns="${3}000000000"
  curl -fsS -m 30 -o /dev/null -u "$PAUTH" -X POST "$HOST/api/public/otel/v1/traces" \
    -H "Content-Type: application/json" -H "x-langfuse-ingestion-version: 4" \
    -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"retention-lab\"}}]},
         \"scopeSpans\":[{\"scope\":{\"name\":\"retention-lab\"},\"spans\":[{\"traceId\":\"$1\",\"spanId\":\"$(openssl rand -hex 8)\",
         \"name\":\"$2\",\"kind\":1,\"startTimeUnixNano\":\"$ns\",\"endTimeUnixNano\":\"$ns\"}]}]}]}"
}
ch_count() { "${CH[@]}" -q "SELECT count() FROM default.events_full FINAL WHERE project_id='$PID' AND is_deleted=0 ${1:-}" < /dev/null; }
wait_rows() { local n=0; for _ in $(seq 1 60); do n=$(ch_count); [ "$n" -ge "$1" ] && return 0; sleep 3; done; echo "✗ $n rows, wanted $1"; exit 1; }
id_of() { "${CH[@]}" -q "SELECT span_id FROM default.events_full FINAL WHERE project_id='$PID' AND trace_id='$1' LIMIT 1" < /dev/null; }
in_ch() { [ "$(ch_count "AND trace_id='$1'")" -ge 1 ]; }

echo "════ 2. Spans: 5 old (start 4 days ago), 1 recent (start 1 hour ago) ════"
T0=$(now_s)
OLD_TIDS=()
for i in 1 2 3 4 5; do t=$(openssl rand -hex 16); OLD_TIDS+=("$t"); span "$t" "old-$i" $((T0 - 4*86400 + i*60)); done
REC_TID=$(openssl rand -hex 16); span "$REC_TID" "recent" $((T0 - 3600))
wait_rows 6
for t in "${OLD_TIDS[@]}"; do id_of "$t"; done > "$WORK/old_ids"
REC_ID=$(id_of "$REC_TID")
echo "  ClickHouse rows: $(ch_count)"

echo "════ 3. Export: PARQUET, weekly, FULL_HISTORY, OBSERVATIONS_V2; Run now; wait for the catch-up ════"
jq -cn --arg p "$PID" --arg b "$BUCKET" --arg u "$MK_USER" --arg s "$MK_PASS" --arg x "$PREFIX" \
  '{projectId:$p,type:"S3_COMPATIBLE",bucketName:$b,endpoint:"http://minio:9000",region:"auto",
    accessKeyId:$u,secretAccessKey:$s,prefix:$x,forcePathStyle:true,fileType:"PARQUET",
    exportFrequency:"weekly",exportMode:"FULL_HISTORY",exportSource:"OBSERVATIONS_V2",enabled:true}' \
  | orgcurl -X PUT "$HOST/api/public/integrations/blob-storage" -H "Content-Type: application/json" -d @- >/dev/null
code=$(run_now); [ "$code" = 200 ] && ok=1 || ok=0; row export "Run now" "HTTP 200" "HTTP $code" $ok
want=$(( $(now_s) - 20*60 - 60 ))
for _ in $(seq 1 100); do
  ls=$("${PSQL[@]}" -tAc "SELECT coalesce(extract(epoch FROM last_sync_at)::bigint::text,'0') FROM blob_storage_integrations WHERE project_id='$PID';" | tr -d '[:space:]')
  [ "$ls" -ge "$want" ] 2>/dev/null && break; sleep 6
done
echo "  last_sync_at = $("${PSQL[@]}" -tAc "SELECT last_sync_at FROM blob_storage_integrations WHERE project_id='$PID';" | sed 's/^ *//')"
archived_ids() {
  "${CH[@]}" -q "SELECT raw_blob FROM s3('$S3/$PREFIX$PID/manifests/*.json', '$MK_USER', '$MK_PASS', 'RawBLOB')
    FORMAT TSVRaw SETTINGS s3_throw_on_zero_files_match = 0" < /dev/null \
    | jq -r '.files[] | select(.key|endswith(".parquet")) | select(.key|contains("/observations_v2/")) | .key' | sort -u > "$WORK/keys"
  while IFS= read -r key; do
    "${CH[@]}" -q "SELECT id FROM s3('$S3/$key', '$MK_USER', '$MK_PASS', 'Parquet') FORMAT TSV" < /dev/null
  done < "$WORK/keys"
}
archived_ids | sort -u > "$WORK/arch1"
n=$(grep -cxFf "$WORK/old_ids" "$WORK/arch1" || true)
[ "$n" = 5 ] && ok=1 || ok=0; row export "old spans in the archive" "5" "$n" $ok
grep -qx "$REC_ID" "$WORK/arch1" && ok=1 || ok=0; row export "recent span in the archive" "present" "$([ $ok = 1 ] && echo present || echo absent)" $ok

echo "════ 4. A late span, also 4 days old, arrives after the export ════"
LATE_TID=$(openssl rand -hex 16); span "$LATE_TID" "late" $((T0 - 4*86400 + 600))
wait_rows 7
LATE_ID=$(id_of "$LATE_TID")
[ -n "$LATE_ID" ] && ok=1 || ok=0; row clickhouse "late span stored (control)" "present" "${LATE_ID:-absent}" $ok

echo "════ 5. Worker with the batch retention cleaner on a 1-minute interval ════"
RESTORE=1
lf_compose ee retention -- up -d langfuse-worker >/dev/null 2>&1
v=$( { lf_compose -- exec -T langfuse-worker printenv LANGFUSE_BATCH_DATA_RETENTION_CLEANER_ENABLED 2>/dev/null || true; } | tr -d '\r')
[ "$v" = true ] && ok=1 || ok=0; row worker "batch retention cleaner enabled" "true" "${v:-unset}" $ok
T_ON=$(now_s)
old_left=99
for _ in $(seq 1 60); do
  old_left=$(ch_count "AND start_time < now() - INTERVAL 3 DAY")
  [ "$old_left" = 0 ] && break; sleep 10
done
echo "  old rows gone after $(( $(now_s) - T_ON )) s"
[ "$old_left" = 0 ] && ok=1 || ok=0; row clickhouse "rows older than 3 days after the cleaner ran" "0" "$old_left" $ok
# Who deleted: the cleaner's statements in ClickHouse's own query log (lightweight DELETE by start_time).
"${CH[@]}" -q "SYSTEM FLUSH LOGS" < /dev/null
nd=$("${CH[@]}" -q "SELECT count() FROM system.query_log WHERE type = 'QueryFinish' AND query_kind = 'Delete'
  AND event_time >= toDateTime($T_ON) - 5 AND query LIKE '%events_full%' AND query LIKE '%$PID%' AND query LIKE '%start_time <%'" < /dev/null)
"${CH[@]}" -q "SELECT event_time, substring(replaceRegexpAll(query, '\\s+', ' '), 1, 160) FROM system.query_log
  WHERE type = 'QueryFinish' AND query_kind = 'Delete' AND event_time >= toDateTime($T_ON) - 5 AND query LIKE '%$PID%'
  ORDER BY event_time FORMAT TSV" < /dev/null | sed 's/^/    /'
[ "$nd" -ge 1 ] 2>/dev/null && ok=1 || ok=0; row clickhouse "the cleaner's DELETE on events_full by start_time (system.query_log)" ">= 1" "$nd" $ok
in_ch "$REC_TID" && ok=1 || ok=0; row clickhouse "recent span kept (control: no over-deletion)" "present" "$([ $ok = 1 ] && echo present || echo absent)" $ok

echo "════ 6. What survives ════"
archived_ids | sort -u > "$WORK/arch2"
n=$(grep -cxFf "$WORK/old_ids" "$WORK/arch2" || true)
[ "$n" = 5 ] && ok=1 || ok=0; row archive "old spans still readable from Parquet after deletion" "5" "$n" $ok
in_ch "$LATE_TID" && ok=0 || ok=1; row clickhouse "late span after the cleaner ran" "absent (deleted)" "$([ $ok = 1 ] && echo absent || echo present)" $ok
grep -qx "$LATE_ID" "$WORK/arch2" && ok=0 || ok=1; row archive "late span in the archive" "absent: lost" "$([ $ok = 1 ] && echo absent || echo present)" $ok

echo "════ Result ════"
column -t -s $'\t' "$ROWS" 2>/dev/null || cat "$ROWS"
echo "  PASS $(grep -c $'\tPASS$' "$ROWS")  FAIL $FAILS"
[ $FAILS = 0 ]
