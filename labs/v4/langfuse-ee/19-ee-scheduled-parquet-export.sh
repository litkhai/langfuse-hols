#!/usr/bin/env bash
# 19-ee-scheduled-parquet-export.sh — does the scheduled blob-storage export write Parquet that holds
# what ClickHouse holds, and what does it leave out?
#
# Step 11 configures the integration and proves the ClickHouse s3() primitive by hand. This step lets
# Langfuse's worker write the files, then reads them back by following the run manifests:
#
#   - spans with start_time 35–127 min in the past are exported (positive), split into one manifest per
#     20-minute window (FULL_HISTORY catches up window by window);
#   - a span inside the 20-minute lag buffer (start_time now − 5 min) is not in the first export
#     (negative) and is in a later one (positive);
#   - a span that arrives late, with start_time before the integration's last_sync_at, is in ClickHouse
#     (control) but in no export: the window filter is `e.start_time` (Langfuse v4.56.0
#     packages/shared/src/server/repositories/events.ts, buildEventsForBlobStorageExportQuery);
#   - Parquet observation files omit input_price / output_price / total_price and keep total_cost
#     (the export docs say so; checked here on the file);
#   - an integration with a wrong secret records last_error and writes no manifest (negative);
#   - an org MEMBER cannot trigger or read the integration (integrations:CRUD is OWNER/ADMIN).
#
# Runs are triggered with the UI's "Run now" (tRPC blobStorageIntegration.runNow) instead of waiting
# for the */20 scheduler tick. Phase 2 waits until the lag-buffer span is older than 20 minutes
# (about 16 minutes after phase 1); --phase1-only skips it.
#
# --license-off: after the setup (which needs the admin API, so the license), restart web + worker
# without the license key and run every export check from section 4 on without it. The entitlement
# `scheduled-blob-exports` is in every self-hosted plan (web/src/features/entitlements/constants/
# entitlements.ts), so the export is expected to work. The EE overlay is restored on exit.
#
# Requires: stack up + EE (05) for the admin API, jq, openssl, ADMIN_API_KEY in _base/.env.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

PHASE2=1; LICENSE_OFF=0
for a in "$@"; do
  case "$a" in
    --phase1-only) PHASE2=0 ;;
    --license-off) LICENSE_OFF=1 ;;
    *) echo "usage: $0 [--phase1-only] [--license-off]"; exit 2 ;;
  esac
done
for c in jq openssl curl; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
ADMIN="Authorization: Bearer ${ADMIN_API_KEY:?set ADMIN_API_KEY in _base/.env}"
BUCKET="${LANGFUSE_S3_BATCH_EXPORT_BUCKET:-langfuse}"
MK_USER="${MINIO_ROOT_USER:-minio}"; MK_PASS="${MINIO_ROOT_PASSWORD:-miniosecret}"
TS=$(date +%Y%m%d%H%M%S)
PREFIX="exports/lab19-$TS/"
WORK=$(mktemp -d); chmod 700 "$WORK"
RESTORE_EE=0
cleanup() {
  rm -rf "$WORK"
  if [ $RESTORE_EE = 1 ]; then
    echo "════ License back on (EE overlay) ════"
    lf_compose ee -- up -d langfuse-web langfuse-worker >/dev/null 2>&1 || true
    wait_web || true
    echo "  admin API → HTTP $(curl -s -o /dev/null -w '%{http_code}' -H "$ADMIN" "$HOST/api/admin/organizations")"
  fi
}
trap cleanup EXIT
wait_web() {
  for _ in $(seq 1 80); do curl -fsS -m 5 "$HOST/api/public/health" >/dev/null 2>&1 && return 0; sleep 3; done
  echo "✗ langfuse-web did not become healthy"; return 1
}

ROWS="$WORK/rows.tsv"; : > "$ROWS"; FAILS=0
row() {  # row <subject> <check> <expected> <observed> <ok:0|1>
  local res=PASS; [ "$5" = 1 ] || { res=FAIL; FAILS=$((FAILS+1)); }
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$res" >> "$ROWS"
  echo "  $res  $1 | $2 | expected: $3 | observed: $4"
}
g() { local n="$1_$2"; echo "${!n}"; }
PSQL=(lf_compose -- exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -P pager=off)
CH=(lf_compose -- exec -T clickhouse clickhouse-client -u "${CLICKHOUSE_USER:-clickhouse}" --password "${CLICKHOUSE_PASSWORD:-clickhouse}")
S3="http://minio:9000/$BUCKET"
now_s() { date +%s; }
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

echo "════ 1. Organization, two projects (good / wrong-secret), keys, two users ════"
ORG_ID=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations" -H "$ADMIN" -H "Content-Type: application/json" \
  -d "{\"name\":\"export-$TS\"}" | jq -r .id)
ORG_KEY=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations/$ORG_ID/apiKeys" -H "$ADMIN" \
  -H "Content-Type: application/json" -d '{"note":"export test"}')
ORG_AUTH="$(echo "$ORG_KEY" | jq -r .publicKey):$(echo "$ORG_KEY" | jq -r .secretKey)"
orgcurl() { curl -fsS -m 30 -u "$ORG_AUTH" "$@"; }
for p in good bad; do
  # The body goes through a variable: bash 3.2 brace-expands a JSON literal inside "$( … )".
  body="{\"name\":\"export-$p-$TS\",\"retention\":0}"
  printf -v "PID_$p" "%s" "$(orgcurl -X POST "$HOST/api/public/projects" -H "Content-Type: application/json" -d "$body" | jq -r .id)"
  K=$(orgcurl -X POST "$HOST/api/public/projects/$(g PID $p)/apiKeys" -H "Content-Type: application/json" -d '{"note":"ingest"}')
  printf -v "PAUTH_$p" "%s" "$(echo "$K" | jq -r .publicKey):$(echo "$K" | jq -r .secretKey)"
  echo "  project $p = $(g PID $p)"
done
echo "  prefix = $PREFIX"

USERS=(expadmin member)
for u in "${USERS[@]}"; do
  printf -v "EMAIL_$u" "%s" "$u-$TS@export.test"
  printf 'Aa1!%s' "$(openssl rand -hex 12)" > "$WORK/pw-$u"
  jq -n --arg e "$(g EMAIL $u)" --arg n "Export $u" --rawfile p "$WORK/pw-$u" '{name:$n,email:$e,password:$p}' \
    | curl -fsS -m 30 -X POST "$HOST/api/auth/signup" -H "Content-Type: application/json" -d @- >/dev/null
done
login() {
  local u=$1 jar="$WORK/jar-$1"; : > "$jar"
  local csrf; csrf=$(curl -fsS -m 30 -c "$jar" -b "$jar" "$HOST/api/auth/csrf" | jq -r .csrfToken)
  curl -sS -m 30 -c "$jar" -b "$jar" -o /dev/null -X POST "$HOST/api/auth/callback/credentials" \
    --data-urlencode "csrfToken=$csrf" --data-urlencode "email=$(g EMAIL $u)" \
    --data-urlencode "password@$WORK/pw-$u" --data-urlencode "callbackUrl=$HOST/" --data-urlencode "json=true"
  curl -fsS -m 30 -b "$jar" -c "$jar" "$HOST/api/auth/session"
}
for u in "${USERS[@]}"; do printf -v "UID__$u" "%s" "$(login "$u" | jq -r '.user.id // empty')"; done
orgcurl -X PUT "$HOST/api/public/organizations/memberships" -H "Content-Type: application/json" \
  -d "{\"userId\":\"$(g UID_ expadmin)\",\"role\":\"ADMIN\"}" >/dev/null
orgcurl -X PUT "$HOST/api/public/organizations/memberships" -H "Content-Type: application/json" \
  -d "{\"userId\":\"$(g UID_ member)\",\"role\":\"MEMBER\"}" >/dev/null
for u in "${USERS[@]}"; do login "$u" >/dev/null; done
trpc_get() {
  curl -sS -m 60 -b "$WORK/jar-$1" -w '\n%{http_code}' -G "$HOST/api/trpc/$2" \
    --data-urlencode "input={\"json\":$3}" | awk 'NR==1{b=$0;next}{print $0" "b}'
}
trpc_post() {
  curl -sS -m 60 -b "$WORK/jar-$1" -w '\n%{http_code}' -X POST "$HOST/api/trpc/$2" \
    -H "Content-Type: application/json" -d "{\"json\":$3}" | awk 'NR==1{b=$0;next}{print $0" "b}'
}
describe() { local c=${1%% *} b=${1#* } e; e=$(echo "$b" | jq -r '.error.json.data.code // empty' 2>/dev/null || true); echo "HTTP $c${e:+ $e}"; }

# span <project> <trace-id> <name> <start epoch seconds>  — one root span over OTLP/JSON
span() {
  local ns="${4}000000000"
  curl -fsS -m 30 -o /dev/null -u "$(g PAUTH "$1")" -X POST "$HOST/api/public/otel/v1/traces" \
    -H "Content-Type: application/json" -H "x-langfuse-ingestion-version: 4" \
    -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"export-lab\"}}]},
         \"scopeSpans\":[{\"scope\":{\"name\":\"export-lab\"},\"spans\":[{\"traceId\":\"$2\",\"spanId\":\"$(openssl rand -hex 8)\",
         \"name\":\"$3\",\"kind\":1,\"startTimeUnixNano\":\"$ns\",\"endTimeUnixNano\":\"$ns\"}]}]}]}"
}
ch_count() {  # ch_count <project> [extra where] — active rows in events_full
  "${CH[@]}" -q "SELECT count() FROM default.events_full FINAL WHERE project_id='$1' AND is_deleted=0 ${2:-}"
}
wait_rows() {  # wait_rows <project> <n> [extra where]
  local n=0
  for _ in $(seq 1 60); do n=$(ch_count "$1" "${3:-}"); [ "$n" -ge "$2" ] && return 0; sleep 3; done
  echo "✗ ClickHouse has $n rows for $1, wanted $2"; exit 1
}

echo "════ 2. Spans: 24 old (start 35–127 min ago), 1 inside the 20-min lag buffer (5 min ago) ════"
T0=$(now_s)
OLD_N=24
for i in $(seq 0 $((OLD_N-1))); do span good "$(openssl rand -hex 16)" "old-$i" $((T0 - (35 + 4*i)*60)); done
BUF_TID=$(openssl rand -hex 16); span good "$BUF_TID" "lag-buffer" $((T0 - 5*60))
span bad "$(openssl rand -hex 16)" "bad-project" $((T0 - 60*60))
wait_rows "$PID_good" $((OLD_N+1)); wait_rows "$PID_bad" 1
echo "  ClickHouse rows: good=$(ch_count "$PID_good")  bad=$(ch_count "$PID_bad")"

put_integration() {  # put_integration <project> <secret> → "<code> <body>"
  jq -cn --arg p "$(g PID "$1")" --arg b "$BUCKET" --arg u "$MK_USER" --arg s "$2" --arg x "$PREFIX" \
    '{projectId:$p,type:"S3_COMPATIBLE",bucketName:$b,endpoint:"http://minio:9000",region:"auto",
      accessKeyId:$u,secretAccessKey:$s,prefix:$x,forcePathStyle:true,fileType:"PARQUET",
      exportFrequency:"every_20_minutes",exportMode:"FULL_HISTORY",exportSource:"OBSERVATIONS_V2",enabled:true}' \
  | curl -sS -m 30 -u "$ORG_AUTH" -w '\n%{http_code}' -X PUT "$HOST/api/public/integrations/blob-storage" \
      -H "Content-Type: application/json" -d @- | awk 'NR==1{b=$0;next}{print $0" "b}'
}
state() {  # state <project> → last_sync_at|backfill|last_error (Postgres)
  "${PSQL[@]}" -tAc "SELECT coalesce(to_char(last_sync_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'null')||'|'||backfill||'|'||coalesce(left(last_error,140),'null')
    FROM blob_storage_integrations WHERE project_id='$(g PID "$1")';" | sed 's/^ *//'
}

echo "════ 3. Integrations (org API): PARQUET, every_20_minutes, FULL_HISTORY, OBSERVATIONS_V2 ════"
r=$(put_integration good "$MK_PASS")
[ "${r%% *}" = 200 ] && ok=1 || ok=0
row good "PUT integration" "HTTP 200" "HTTP ${r%% *} $(echo "${r#* }" | jq -c '{fileType,exportFrequency,exportMode,exportSource}' 2>/dev/null)" $ok
r=$(put_integration bad "wrong-$(openssl rand -hex 6)")
BAD_PUT=${r%% *}
# Saving does not test the credentials (the UI's separate "Validate" button does); the run fails later.
[ "$BAD_PUT" = 200 ] && ok=1 || ok=0
row bad "PUT integration with a wrong secret" "HTTP 200 (not checked on save)" "HTTP $BAD_PUT" $ok

if [ $LICENSE_OFF = 1 ]; then
  echo "════ 3b. License off: restart web + worker without the EE overlay ════"
  RESTORE_EE=1
  lf_compose -- up -d langfuse-web langfuse-worker >/dev/null 2>&1
  wait_web
  k=$( { lf_compose -- exec -T langfuse-worker printenv LANGFUSE_EE_LICENSE_KEY 2>/dev/null || true; } | wc -c | tr -d ' ')
  [ "$k" -le 1 ] && ok=1 || ok=0; row stack "license key in langfuse-worker after restart" "absent" "$([ "$k" -le 1 ] && echo absent || echo present)" $ok
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "$ADMIN" "$HOST/api/admin/organizations")
  [ "$code" != 200 ] && ok=1 || ok=0; row stack "admin API without the license (control: EE is off)" "not 200" "HTTP $code" $ok
  for u in "${USERS[@]}"; do login "$u" >/dev/null; done
fi

echo "════ 4. Who may run it: MEMBER denied, ADMIN runs it ════"
r=$(trpc_post member blobStorageIntegration.runNow "{\"projectId\":\"$PID_good\"}")
describe "$r" | grep -q '^HTTP 403 FORBIDDEN$' && ok=1 || ok=0; row member "Run now (blobStorageIntegration.runNow)" "HTTP 403 FORBIDDEN" "$(describe "$r")" $ok
r=$(trpc_get member blobStorageIntegration.get "{\"projectId\":\"$PID_good\"}")
describe "$r" | grep -q '^HTTP 403 FORBIDDEN$' && ok=1 || ok=0; row member "read the integration (blobStorageIntegration.get)" "HTTP 403 FORBIDDEN" "$(describe "$r")" $ok
RUN1=$(now_s)
r=$(trpc_post expadmin blobStorageIntegration.runNow "{\"projectId\":\"$PID_good\"}")
[ "${r%% *}" = 200 ] && ok=1 || ok=0; row expadmin "Run now (good project)" "HTTP 200" "$(describe "$r")" $ok
if [ "$BAD_PUT" = 200 ]; then
  r=$(trpc_post expadmin blobStorageIntegration.runNow "{\"projectId\":\"$PID_bad\"}")
  echo "  Run now (bad project) → $(describe "$r")"
fi

# wait_caught_up <project> <run start epoch> — until last_sync_at >= run start − 20 min − 60 s
wait_caught_up() {
  local want=$(( $2 - 20*60 - 60 )) st ls lse
  for _ in $(seq 1 100); do
    st=$(state "$1"); ls=${st%%|*}
    if [ "$ls" != null ]; then
      lse=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${ls%.*}" +%s 2>/dev/null || date -u -d "${ls}" +%s)
      [ "$lse" -ge "$want" ] && { echo "  caught up: $st"; return 0; }
    fi
    sleep 6
  done
  echo "✗ export for $1 did not catch up: $(state "$1")"; return 1
}
wait_error() {
  for _ in $(seq 1 50); do st=$(state "$1"); [ "${st##*|}" != null ] && { echo "  $st"; return 0; }; sleep 6; done
  echo "  no last_error after 5 min: $(state "$1")"; return 0
}

manifests() {  # manifests <project> → one manifest JSON per line, sorted by key
  "${CH[@]}" -q "SELECT raw_blob FROM s3('$S3/$PREFIX$(g PID "$1")/manifests/*.json', '$MK_USER', '$MK_PASS', 'RawBLOB')
    ORDER BY _file FORMAT TSVRaw SETTINGS s3_throw_on_zero_files_match = 0" | jq -c . 2>/dev/null || true
}
exported_ids() {  # exported_ids <project> → one line per exported row id (from every manifest's files)
  local key
  manifests "$1" | jq -r '.files[] | select(.format=="parquet" or (.key|endswith(".parquet"))) | .key' | sort -u > "$WORK/keys"
  : > "$WORK/ids"
  while IFS= read -r key; do
    # </dev/null: `docker compose exec -T` reads stdin and would swallow the rest of the key list.
    "${CH[@]}" -q "SELECT id FROM s3('$S3/$key', '$MK_USER', '$MK_PASS', 'Parquet') FORMAT TSV" < /dev/null >> "$WORK/ids"
  done < "$WORK/keys"
  cat "$WORK/ids"
}
span_id_of() {  # span_id_of <trace id> → observation id in ClickHouse (events_full.span_id = Parquet `id`)
  "${CH[@]}" -q "SELECT span_id FROM default.events_full FINAL WHERE project_id='$PID_good' AND trace_id='$1' LIMIT 1"
}

echo "════ 5. Phase 1: wait for the catch-up, then read the manifests and the Parquet ════"
wait_caught_up good "$RUN1"
manifests good > "$WORK/m1"
nm=$(wc -l < "$WORK/m1" | tr -d ' ')
echo "  manifests: $nm"
jq -r '"    " + .window.minTimestamp + " → " + .window.maxTimestamp + "  files=" + (.files|length|tostring) + "  " + ([.files[].key|split("/")|.[-2:]|join("/")]|join(","))' "$WORK/m1"
[ "$nm" -ge 2 ] && ok=1 || ok=0; row good "one manifest per 20-min window (FULL_HISTORY catch-up)" ">= 2 manifests" "$nm" $ok
exported_ids good > "$WORK/ids1"
n_rows=$(wc -l < "$WORK/ids1" | tr -d ' '); n_dist=$(sort -u "$WORK/ids1" | wc -l | tr -d ' ')
LAST1=$(state good); LAST1=${LAST1%%|*}
n_ch=$(ch_count "$PID_good" "AND start_time < parseDateTime64BestEffort('$LAST1', 3)")
[ "$n_dist" = "$OLD_N" ] && [ "$n_dist" = "$n_ch" ] && ok=1 || ok=0
row good "distinct ids in Parquet = ClickHouse rows with start_time < last_sync_at" "$OLD_N = $OLD_N" "$n_dist (rows $n_rows) = $n_ch" $ok
BUF_ID=$(span_id_of "$BUF_TID")
[ -n "$BUF_ID" ] && ok=1 || ok=0; row good "lag-buffer span is in ClickHouse (control)" "present" "${BUF_ID:-absent}" $ok
grep -qx "$BUF_ID" "$WORK/ids1" && ok=0 || ok=1
row good "lag-buffer span (start now−5 min) in phase-1 export" "absent" "$(grep -qx "$BUF_ID" "$WORK/ids1" && echo present || echo absent)" $ok

FIRST_KEY=$(head -1 "$WORK/keys")
"${CH[@]}" -q "DESCRIBE TABLE s3('$S3/$FIRST_KEY', '$MK_USER', '$MK_PASS', 'Parquet') FORMAT TSV" | cut -f1 > "$WORK/cols"
echo "  Parquet columns: $(wc -l < "$WORK/cols" | tr -d ' ') ($(head -8 "$WORK/cols" | tr '\n' ' ')…)"
np=$(grep -cxE 'input_price|output_price|total_price' "$WORK/cols" || true); nc=$(grep -cx 'total_cost' "$WORK/cols" || true)
[ "$np" = 0 ] && [ "$nc" = 1 ] && ok=1 || ok=0
row good "Parquet columns: no *_price, has total_cost (docs claim)" "0 price columns, total_cost" "$np price columns, total_cost=$nc" $ok
echo "  file format (magic bytes of the first file): $("${CH[@]}" -q "SELECT substring(raw_blob,1,4) FROM s3('$S3/$FIRST_KEY', '$MK_USER', '$MK_PASS', 'RawBLOB') FORMAT TSVRaw")"

echo "════ 6. The wrong-secret integration ════"
if [ "$BAD_PUT" = 200 ]; then
  wait_error bad
  st=$(state bad); le=${st##*|}
  [ "$le" != null ] && ok=1 || ok=0; row bad "last_error recorded" "an error" "$le" $ok
  [ "$(manifests bad | wc -l | tr -d ' ')" = 0 ] && ok=1 || ok=0; row bad "manifests written" "0" "$(manifests bad | wc -l | tr -d ' ')" $ok
fi

if [ $PHASE2 = 1 ]; then
  echo "════ 7. Phase 2: a late span (start before last_sync_at), then wait out the lag buffer ════"
  LATE_TID=$(openssl rand -hex 16); span good "$LATE_TID" "late-arrival" $((T0 - 60*60))
  wait_rows "$PID_good" $((OLD_N+2))
  LATE_ID=$(span_id_of "$LATE_TID")
  [ -n "$LATE_ID" ] && ok=1 || ok=0; row good "late span (start now−60 min, sent after phase 1) in ClickHouse (control)" "present" "${LATE_ID:-absent}" $ok
  until_s=$(( T0 - 5*60 + 20*60 + 90 ))
  echo "  waiting until $(iso "$until_s") (lag-buffer span older than 20 min)…"
  while [ "$(now_s)" -lt "$until_s" ]; do sleep 30; done
  for u in "${USERS[@]}"; do login "$u" >/dev/null; done
  RUN2=$(now_s)
  r=$(trpc_post expadmin blobStorageIntegration.runNow "{\"projectId\":\"$PID_good\"}")
  [ "${r%% *}" = 200 ] && ok=1 || ok=0; row expadmin "Run now (phase 2)" "HTTP 200" "$(describe "$r")" $ok
  wait_caught_up good "$RUN2"
  manifests good > "$WORK/m2"
  echo "  manifests now: $(wc -l < "$WORK/m2" | tr -d ' ')"
  jq -r '"    " + .window.minTimestamp + " → " + .window.maxTimestamp + "  files=" + (.files|length|tostring)' "$WORK/m2"
  exported_ids good > "$WORK/ids2"
  grep -qx "$BUF_ID" "$WORK/ids2" && ok=1 || ok=0
  row good "lag-buffer span in a later export" "present" "$(grep -qx "$BUF_ID" "$WORK/ids2" && echo present || echo absent)" $ok
  grep -qx "$LATE_ID" "$WORK/ids2" && ok=0 || ok=1
  row good "late span in any export" "absent (window filter is start_time)" "$(grep -qx "$LATE_ID" "$WORK/ids2" && echo present || echo absent)" $ok
  n_dist=$(sort -u "$WORK/ids2" | wc -l | tr -d ' '); n_all=$(ch_count "$PID_good")
  [ "$n_dist" = $((n_all-1)) ] && ok=1 || ok=0
  row good "distinct exported ids vs ClickHouse rows" "ClickHouse − 1 (the late span)" "$n_dist vs $n_all" $ok
fi

echo "════ Objects under the prefix (MinIO) ════"
"${CH[@]}" -q "SELECT replaceRegexpOne(_path, '^[^/]+/', '') AS key, _size AS bytes FROM s3('$S3/$PREFIX**', '$MK_USER', '$MK_PASS', 'One')
  ORDER BY key FORMAT TSV SETTINGS s3_throw_on_zero_files_match = 0" || true

echo "════ Result ════"
column -t -s $'\t' "$ROWS" 2>/dev/null || cat "$ROWS"
echo "  PASS $(grep -c $'\tPASS$' "$ROWS")  FAIL $FAILS"
[ $FAILS = 0 ]
