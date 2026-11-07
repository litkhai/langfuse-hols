#!/usr/bin/env bash
# 21-ee-export-object-lock.sh — can the scheduled Parquet export write into an immutable (WORM) bucket?
#
# A regulated archive is usually write-once: S3 Object Lock with a default retention. This step creates a
# MinIO bucket with object lock and a default GOVERNANCE retention of 1 day, points a scheduled Parquet
# export at it, and checks:
#   - the run succeeds (last_error empty), the manifest and the Parquet are written and readable (positive);
#   - each written object carries the GOVERNANCE retention;
#   - deleting a written object version is refused (WORM), while the same delete succeeds on an object in a
#     bucket without object lock (control: the delete command itself works).
# GOVERNANCE (not COMPLIANCE) so an operator can still clean up with a bypass; the bucket is left in place.
#
# Requires: stack up + EE (05), jq, openssl, ADMIN_API_KEY in _base/.env. Uses `mc` inside the MinIO container.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

for c in jq openssl curl; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
ADMIN="Authorization: Bearer ${ADMIN_API_KEY:?set ADMIN_API_KEY in _base/.env}"
MK_USER="${MINIO_ROOT_USER:-minio}"; MK_PASS="${MINIO_ROOT_PASSWORD:-miniosecret}"
TS=$(date +%Y%m%d%H%M%S)
WORM="lab21-worm-$TS"
PREFIX="exports/"
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT

ROWS="$WORK/rows.tsv"; : > "$ROWS"; FAILS=0
row() {
  local res=PASS; [ "$5" = 1 ] || { res=FAIL; FAILS=$((FAILS+1)); }
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$res" >> "$ROWS"
  echo "  $res  $1 | $2 | expected: $3 | observed: $4"
}
PSQL=(lf_compose -- exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -P pager=off)
CH=(lf_compose -- exec -T clickhouse clickhouse-client -u "${CLICKHOUSE_USER:-clickhouse}" --password "${CLICKHOUSE_PASSWORD:-clickhouse}")
mcx() { lf_compose -- exec -T minio mc "$@" < /dev/null; }

echo "════ 1. A MinIO bucket with object lock and a default GOVERNANCE retention of 1 day ════"
mcx alias set lab http://localhost:9000 "$MK_USER" "$MK_PASS" >/dev/null
mcx mb --with-lock "lab/$WORM" >/dev/null
mcx retention set --default GOVERNANCE 1d "lab/$WORM" >/dev/null
mode=$(mcx retention info --default --json "lab/$WORM" | jq -r '.mode // .Mode // empty' 2>/dev/null || true)
[ "$mode" = GOVERNANCE ] && ok=1 || ok=0; row bucket "default retention of $WORM" "GOVERNANCE" "${mode:-none}" $ok

echo "════ 2. Organization, project, key, ADMIN user; 3 spans 1–2 hours old ════"
ORG_ID=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations" -H "$ADMIN" -H "Content-Type: application/json" \
  -d "{\"name\":\"worm-$TS\"}" | jq -r .id)
ORG_KEY=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations/$ORG_ID/apiKeys" -H "$ADMIN" \
  -H "Content-Type: application/json" -d '{"note":"worm test"}')
ORG_AUTH="$(echo "$ORG_KEY" | jq -r .publicKey):$(echo "$ORG_KEY" | jq -r .secretKey)"
orgcurl() { curl -fsS -m 30 -u "$ORG_AUTH" "$@"; }
body="{\"name\":\"worm-$TS\",\"retention\":0}"   # a variable: bash 3.2 brace-expands a JSON literal inside "$( … )"
PID=$(orgcurl -X POST "$HOST/api/public/projects" -H "Content-Type: application/json" -d "$body" | jq -r .id)
K=$(orgcurl -X POST "$HOST/api/public/projects/$PID/apiKeys" -H "Content-Type: application/json" -d '{"note":"ingest"}')
PAUTH="$(echo "$K" | jq -r .publicKey):$(echo "$K" | jq -r .secretKey)"
EMAIL="expadmin-$TS@worm.test"
printf 'Aa1!%s' "$(openssl rand -hex 12)" > "$WORK/pw"
jq -n --arg e "$EMAIL" --rawfile p "$WORK/pw" '{name:"Worm admin",email:$e,password:$p}' \
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
T0=$(date +%s)
for i in 1 2 3; do
  ns="$((T0 - 3600 - i*600))000000000"
  curl -fsS -m 30 -o /dev/null -u "$PAUTH" -X POST "$HOST/api/public/otel/v1/traces" \
    -H "Content-Type: application/json" -H "x-langfuse-ingestion-version: 4" \
    -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[]},\"scopeSpans\":[{\"scope\":{\"name\":\"worm\"},\"spans\":[{\"traceId\":\"$(openssl rand -hex 16)\",
         \"spanId\":\"$(openssl rand -hex 8)\",\"name\":\"worm-$i\",\"kind\":1,\"startTimeUnixNano\":\"$ns\",\"endTimeUnixNano\":\"$ns\"}]}]}]}"
done
for _ in $(seq 1 60); do
  n=$("${CH[@]}" -q "SELECT count() FROM default.events_full FINAL WHERE project_id='$PID' AND is_deleted=0" < /dev/null)
  [ "$n" -ge 3 ] && break; sleep 3
done
echo "  ClickHouse rows: $n"

echo "════ 3. Export into the WORM bucket (PARQUET, hourly, FULL_HISTORY), Run now ════"
jq -cn --arg p "$PID" --arg b "$WORM" --arg u "$MK_USER" --arg s "$MK_PASS" --arg x "$PREFIX" \
  '{projectId:$p,type:"S3_COMPATIBLE",bucketName:$b,endpoint:"http://minio:9000",region:"auto",
    accessKeyId:$u,secretAccessKey:$s,prefix:$x,forcePathStyle:true,fileType:"PARQUET",
    exportFrequency:"hourly",exportMode:"FULL_HISTORY",exportSource:"OBSERVATIONS_V2",enabled:true}' \
  | orgcurl -X PUT "$HOST/api/public/integrations/blob-storage" -H "Content-Type: application/json" -d @- >/dev/null
code=$(curl -sS -m 60 -b "$WORK/jar" -o /dev/null -w '%{http_code}' -X POST "$HOST/api/trpc/blobStorageIntegration.runNow" \
  -H "Content-Type: application/json" -d "{\"json\":{\"projectId\":\"$PID\"}}")
[ "$code" = 200 ] && ok=1 || ok=0; row export "Run now" "HTTP 200" "HTTP $code" $ok
want=$(( $(date +%s) - 20*60 - 60 )); st=""
for _ in $(seq 1 60); do
  st=$("${PSQL[@]}" -tAc "SELECT coalesce(extract(epoch FROM last_sync_at)::bigint::text,'0')||'|'||coalesce(left(last_error,160),'')
       FROM blob_storage_integrations WHERE project_id='$PID';" | sed 's/^ *//')
  [ -n "${st#*|}" ] && break
  [ "${st%%|*}" -ge "$want" ] 2>/dev/null && break
  sleep 6
done
le=${st#*|}
[ -z "$le" ] && ok=1 || ok=0; row export "last_error after the run" "empty" "${le:-empty}" $ok

echo "════ 4. What the run wrote, and whether it can be deleted ════"
mcx ls --recursive "lab/$WORM/$PREFIX$PID/" | sed 's/^/  /'
MAN=$(mcx ls --recursive --json "lab/$WORM/$PREFIX$PID/manifests/" | jq -r '.key' | head -1)
[ -n "$MAN" ] && ok=1 || ok=0; row export "manifest written" "present" "${MAN:-absent}" $ok
PQ=$(mcx cat "lab/$WORM/$PREFIX$PID/manifests/$MAN" | jq -r '.files[] | select(.key|contains("/observations_v2/")) | .key' | head -1)
n=$("${CH[@]}" -q "SELECT count() FROM s3('http://minio:9000/$WORM/$PQ', '$MK_USER', '$MK_PASS', 'Parquet')" < /dev/null)
[ "$n" = 3 ] && ok=1 || ok=0; row export "rows in the Parquet (read with ClickHouse s3())" "3" "$n" $ok
rmode=$(mcx retention info --json "lab/$WORM/$PQ" | jq -r '.mode // .Mode // empty' 2>/dev/null || true)
[ "$rmode" = GOVERNANCE ] && ok=1 || ok=0; row worm "retention on the written Parquet" "GOVERNANCE" "${rmode:-none}" $ok
VID=$(mcx stat --json "lab/$WORM/$PQ" | jq -r '.versionID // empty')
out=$(mcx rm --version-id "$VID" "lab/$WORM/$PQ" 2>&1 || true)
still=$(mcx stat --version-id "$VID" --json "lab/$WORM/$PQ" 2>/dev/null | jq -r '.versionID // empty' || true)
[ "$still" = "$VID" ] && ok=1 || ok=0
row worm "delete that version (mc rm --version-id)" "refused, version kept" "$(echo "$out" | tr '\n' ' ' | grep -o -i -E 'is WORM protected[^.]*|retention[^.]*|access denied[^.]*' | head -1); kept=$([ -n "$still" ] && echo yes || echo no)" $ok
# Control: the same command on an unlocked bucket deletes.
CTRL="lab21-plain-$TS"
mcx mb "lab/$CTRL" >/dev/null
echo control | lf_compose -- exec -T minio mc pipe "lab/$CTRL/control.txt" >/dev/null
CV=$(mcx stat --json "lab/$CTRL/control.txt" | jq -r '.versionID // empty')
mcx rm ${CV:+--version-id "$CV"} "lab/$CTRL/control.txt" >/dev/null 2>&1 || true
gone=$(mcx stat "lab/$CTRL/control.txt" >/dev/null 2>&1 && echo no || echo yes)
[ "$gone" = yes ] && ok=1 || ok=0; row control "delete on a bucket without object lock" "deleted" "$([ $gone = yes ] && echo deleted || echo kept)" $ok
mcx rb --force "lab/$CTRL" >/dev/null 2>&1 || true

echo "════ Result ════"
column -t -s $'\t' "$ROWS" 2>/dev/null || cat "$ROWS"
echo "  PASS $(grep -c $'\tPASS$' "$ROWS")  FAIL $FAILS"
echo "  the WORM bucket $WORM stays (GOVERNANCE, 1 day); remove it with: mc rm --recursive --force --bypass --versions lab/$WORM && mc rb lab/$WORM"
[ $FAILS = 0 ]
