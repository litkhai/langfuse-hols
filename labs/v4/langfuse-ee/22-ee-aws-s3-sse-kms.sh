#!/usr/bin/env bash
# 22-ee-aws-s3-sse-kms.sh — the event and media buckets on AWS S3, encrypted with a customer-managed KMS key.
#
# A regulated deployment moving off an on-premises S3-compatible store wants both Langfuse buckets on AWS S3,
# encrypted with its own KMS key, because LLM inputs may carry images of identity documents. This step:
#   1. creates one customer-managed KMS key and two buckets (events, media) in one region: default SSE-KMS
#      with that key + S3 Bucket Key, public access blocked, 30-day expiry on raw events, and a bucket policy
#      that refuses non-TLS requests and any PUT that asks for a different encryption or key;
#   2. checks that policy with the aws CLI as the writer;
#   3. recommended setup (overlays aws-s3 + aws-s3-sse): Langfuse sets SSE-KMS on its own event writes, media
#      relies on the bucket default. One trace through the Python SDK (LangfuseMedia, presigned PUT) and one
#      as raw OTLP with a base64 data URI, with the worker's OTLP media extraction off (Langfuse default);
#   4. the same raw OTLP trace with the extraction on (LAB22_OTEL_MEDIA=true), then where the image bytes
#      ended up in the raw event objects;
#   5. reading the image back through the presigned GET URL, and that URL expiring;
#   6. LANGFUSE_S3_MEDIA_UPLOAD_SSE set as well (overlay aws-s3-media-sse): SDK uploads over the presigned
#      URL fail, shown with a hand-made PUT with and without the signed SSE headers.
#
#   22-ee-aws-s3-sse-kms.sh            run (creates the AWS resources on the first run, reuses them after)
#   22-ee-aws-s3-sse-kms.sh --cleanup  empty and delete both buckets, schedule the key for deletion (7 days),
#                                      put web + worker back on MinIO
#
# Requires: stack up (01, EE optional), aws CLI v2 with credentials in the shell (AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN; s3, kms:CreateKey/CreateAlias/ScheduleKeyDeletion), jq, curl,
# shasum, xxd, .venv-v4 with _base/v4/requirements.txt. Region: LAB22_REGION (default ap-northeast-2).
# State (bucket names, key ARN) is kept in _base/.env.lab22 (gitignored) until --cleanup.
# Cost: one KMS key ($1/month, prorated) plus a few hundred S3/KMS requests — well under $1 per run.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

for c in aws jq curl shasum xxd; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
PY="$BASE_DIR/../.venv-v4/bin/python"; [[ -x "$PY" ]] || PY="$(command -v python3)"
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
export LAB22_REGION="${LAB22_REGION:-ap-northeast-2}" AWS_REGION="${LAB22_REGION:-ap-northeast-2}"
export LAB22_MEDIA_URL_EXPIRY="${LAB22_MEDIA_URL_EXPIRY:-60}"
STATE="$BASE_DIR/.env.lab22"
export LAB22_PK="${LANGFUSE_INIT_PROJECT_PUBLIC_KEY:?set in _base/.env}" LAB22_SK="${LANGFUSE_INIT_PROJECT_SECRET_KEY:?set in _base/.env}"
PROJECT_ID="${LANGFUSE_INIT_PROJECT_ID:?set in _base/.env}"
BASEOV=(aws-s3); [[ -n "${LANGFUSE_EE_LICENSE_KEY:-}" ]] && BASEOV=(ee aws-s3)
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT

wait_web() {
  for _ in $(seq 1 90); do curl -fsS -m 5 "$HOST/api/public/health" >/dev/null 2>&1 && return 0; sleep 5; done
  echo "✗ langfuse-web did not become healthy"; exit 1
}
# langfuse web + worker on the given overlays (the rest of the stack is left as it is)
langfuse_on() { lf_compose "$@" -- up -d --no-deps --force-recreate langfuse-web langfuse-worker >/dev/null 2>&1; wait_web; sleep 10; }

if [[ "${1:-}" == "--cleanup" ]]; then
  [[ -f "$STATE" ]] || { echo "nothing to clean: $STATE not found"; exit 0; }
  . "$STATE"
  for b in "$LAB22_EVENT_BUCKET" "$LAB22_MEDIA_BUCKET"; do
    aws s3 rm "s3://$b" --recursive --only-show-errors || true
    aws s3api delete-bucket --bucket "$b" && echo "  deleted bucket $b"
  done
  aws kms delete-alias --alias-name "$LAB22_KMS_ALIAS" || true
  aws kms schedule-key-deletion --key-id "$LAB22_KMS_KEY_ARN" --pending-window-in-days 7 \
    --query 'DeletionDate' --output text | sed 's/^/  key deletion scheduled for /'
  rm -f "$STATE"
  OV=(); [[ -n "${LANGFUSE_EE_LICENSE_KEY:-}" ]] && OV=(ee)
  lf_compose ${OV[@]+"${OV[@]}"} -- up -d --no-deps --force-recreate langfuse-web langfuse-worker >/dev/null 2>&1; wait_web
  echo "  langfuse web + worker back on MinIO"
  exit 0
fi

ROWS="$WORK/rows.tsv"; : > "$ROWS"; FAILS=0
row() {
  local res=PASS; [ "$5" = 1 ] || { res=FAIL; FAILS=$((FAILS+1)); }
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$res" >> "$ROWS"
  echo "  $res  $1 | $2 | expected: $3 | observed: $4"
}
PSQL=(lf_compose -- exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tA -P pager=off)
CH=(lf_compose -- exec -T clickhouse clickhouse-client -u "${CLICKHOUSE_USER:-clickhouse}" --password "${CLICKHOUSE_PASSWORD:-clickhouse}")
send() { "$PY" 22-send-media.py "$@" > "$WORK/send.out" 2>"$WORK/send.err" || true; }
field() { awk -v k="$1" '$1==k{print $2}' "$WORK/send.out"; }
# input of the trace's observations as ClickHouse stores it (v4 events table), waits up to 90 s
ch_input() {
  local out=""
  for _ in $(seq 1 30); do
    out=$("${CH[@]}" -q "SELECT input FROM events_full WHERE project_id='$PROJECT_ID' AND trace_id='$1' FORMAT TSVRaw" 2>/dev/null || true)
    [[ -n "$out" ]] && break; sleep 3
  done
  printf '%s' "$out"
}
media_id() { { grep -o '@@@langfuseMedia:[^@]*@@@' <<<"$1" || true; } | head -1 | sed -n 's/.*|id=\([^|]*\)|.*/\1/p'; }
sse_of() { aws s3api head-object --bucket "$1" --key "$2" --query '[ServerSideEncryption,SSEKMSKeyId,BucketKeyEnabled]' --output text 2>/dev/null | tr '\t' ' ' || true; }
lab_key() { local s; s=$(sse_of "$@"); echo "${s/$LAB22_KMS_KEY_ARN/lab-key}"; }
denied() { grep -o 'AccessDenied\|SignatureDoesNotMatch' "$1" | head -1 || true; }
inline_or_ref() {  # $1 ClickHouse input, $2 base64 marker
  if [[ "$1" == *"$2"* ]]; then echo "base64 inline"; elif [[ "$1" == *"@@@langfuseMedia:"* ]]; then echo "media reference";
  else echo "neither: ${1:0:80}"; fi
}

echo "════ 1. KMS key and two buckets in $LAB22_REGION ════"
if [[ -f "$STATE" ]]; then
  . "$STATE"; echo "  reusing $LAB22_EVENT_BUCKET, $LAB22_MEDIA_BUCKET and $LAB22_KMS_ALIAS"
else
  TS=$(date +%Y%m%d%H%M%S); SUF=$(openssl rand -hex 3)
  LAB22_EVENT_BUCKET="lfhols22-events-$TS-$SUF"; LAB22_MEDIA_BUCKET="lfhols22-media-$TS-$SUF"
  LAB22_KMS_ALIAS="alias/lfhols22-$TS"
  LAB22_KMS_KEY_ARN=$(aws kms create-key --description "langfuse-hols lab 22 ($TS)" \
    --tags TagKey=lab,TagValue=langfuse-hols-22 --query KeyMetadata.Arn --output text)
  aws kms create-alias --alias-name "$LAB22_KMS_ALIAS" --target-key-id "$LAB22_KMS_KEY_ARN"
  for b in "$LAB22_EVENT_BUCKET" "$LAB22_MEDIA_BUCKET"; do
    aws s3api create-bucket --bucket "$b" --create-bucket-configuration "LocationConstraint=$LAB22_REGION" >/dev/null
    aws s3api put-bucket-tagging --bucket "$b" --tagging 'TagSet=[{Key=lab,Value=langfuse-hols-22}]'
    aws s3api put-public-access-block --bucket "$b" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    aws s3api put-bucket-encryption --bucket "$b" --server-side-encryption-configuration \
      "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$LAB22_KMS_KEY_ARN\"},\"BucketKeyEnabled\":true}]}"
  done
  aws s3api put-bucket-lifecycle-configuration --bucket "$LAB22_EVENT_BUCKET" --lifecycle-configuration \
    '{"Rules":[{"ID":"expire-raw-events","Status":"Enabled","Filter":{"Prefix":"events/"},"Expiration":{"Days":30}}]}' >/dev/null
  umask 077
  printf 'LAB22_EVENT_BUCKET=%s\nLAB22_MEDIA_BUCKET=%s\nLAB22_KMS_KEY_ARN=%s\nLAB22_KMS_ALIAS=%s\n' \
    "$LAB22_EVENT_BUCKET" "$LAB22_MEDIA_BUCKET" "$LAB22_KMS_KEY_ARN" "$LAB22_KMS_ALIAS" > "$STATE"
  echo "  created $LAB22_EVENT_BUCKET, $LAB22_MEDIA_BUCKET, $LAB22_KMS_ALIAS"
fi
export LAB22_EVENT_BUCKET LAB22_MEDIA_BUCKET LAB22_KMS_KEY_ARN
# The policy is (re)applied on every run. Each deny needs the header to be present (Null = false) AND to differ:
# a PUT without an encryption header is allowed and gets the bucket default (the lab key); a PUT that names
# another algorithm or another key is refused. (StringNotEqualsIfExists would not do this: a missing key makes an
# ...IfExists condition true, so it denies header-less PUTs too.)
for b in "$LAB22_EVENT_BUCKET" "$LAB22_MEDIA_BUCKET"; do
  aws s3api put-bucket-policy --bucket "$b" --policy "$(jq -nc --arg b "$b" --arg k "$LAB22_KMS_KEY_ARN" '{
    Version: "2012-10-17", Statement: [
      {Sid: "DenyNonTLS", Effect: "Deny", Principal: "*", Action: "s3:*",
       Resource: ["arn:aws:s3:::\($b)", "arn:aws:s3:::\($b)/*"], Condition: {Bool: {"aws:SecureTransport": "false"}}},
      {Sid: "DenyOtherEncryption", Effect: "Deny", Principal: "*", Action: "s3:PutObject", Resource: "arn:aws:s3:::\($b)/*",
       Condition: {StringNotEquals: {"s3:x-amz-server-side-encryption": "aws:kms"},
                  Null: {"s3:x-amz-server-side-encryption": "false"}}},
      {Sid: "DenyOtherKey", Effect: "Deny", Principal: "*", Action: "s3:PutObject", Resource: "arn:aws:s3:::\($b)/*",
       Condition: {StringNotEquals: {"s3:x-amz-server-side-encryption-aws-kms-key-id": $k},
                  Null: {"s3:x-amz-server-side-encryption-aws-kms-key-id": "false"}}}]}')"
  enc=$(aws s3api get-bucket-encryption --bucket "$b" --query \
    'ServerSideEncryptionConfiguration.Rules[0].[ApplyServerSideEncryptionByDefault.SSEAlgorithm,ApplyServerSideEncryptionByDefault.KMSMasterKeyID==`'"$LAB22_KMS_KEY_ARN"'`,BucketKeyEnabled]' --output text | tr '\t' ' ')
  [ "$enc" = "aws:kms True True" ] && ok=1 || ok=0; row bucket "default encryption, ${b%%-2*}" "aws:kms, lab key, bucket key" "$enc" $ok
  pab=$(aws s3api get-public-access-block --bucket "$b" --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text | tr '\t' ' ')
  [ "$pab" = "True True True True" ] && ok=1 || ok=0; row bucket "public access block, ${b%%-2*}" "all four on" "$pab" $ok
done
lc=$(aws s3api get-bucket-lifecycle-configuration --bucket "$LAB22_EVENT_BUCKET" --query 'Rules[0].Expiration.Days' --output text)
[ "$lc" = 30 ] && ok=1 || ok=0; row bucket "event bucket lifecycle" "events/ expire after 30 days" "$lc days" $ok

echo "════ 2. The bucket policy on its own (aws CLI as the writer) ════"
echo probe > "$WORK/probe.txt"; MB="$LAB22_MEDIA_BUCKET"
put_probe() {  # $1 key, rest: extra put-object args → "written (<encryption>)" or the denial code
  local k="$1"; shift
  if aws s3api put-object --bucket "$MB" --key "lab22/$k" --body "$WORK/probe.txt" "$@" >/dev/null 2>"$WORK/err"; then
    echo "written ($(lab_key "$MB" "lab22/$k"))"; else d=$(denied "$WORK/err"); echo "${d:-$(head -c 100 "$WORK/err")}"; fi
}
o=$(put_probe plain.txt); [[ "$o" == "written (aws:kms lab-key True)" ]] && ok=1 || ok=0
row policy "PUT without an encryption header" "written, bucket default (lab key)" "$o" $ok
o=$(put_probe aes.txt --server-side-encryption AES256); [ "$o" = AccessDenied ] && ok=1 || ok=0
row policy "PUT asking for SSE-S3 (AES256)" "AccessDenied" "$o" $ok
o=$(put_probe awsmanaged.txt --server-side-encryption aws:kms --ssekms-key-id alias/aws/s3); [ "$o" = AccessDenied ] && ok=1 || ok=0
row policy "PUT asking for SSE-KMS with the AWS managed key" "AccessDenied" "$o" $ok
o=$(put_probe kms-nokey.txt --server-side-encryption aws:kms)
# Without a key id S3 would pick the AWS managed key; observed: refused (which statement matched is not identified).
row policy "PUT asking for SSE-KMS without a key id" "AccessDenied or the lab key, never another key" "$o" "$([[ "$o" = AccessDenied || "$o" = "written (aws:kms lab-key True)" ]] && echo 1 || echo 0)"
o=$(put_probe kms.txt --server-side-encryption aws:kms --ssekms-key-id "$LAB22_KMS_KEY_ARN"); [[ "$o" == "written (aws:kms lab-key True)" ]] && ok=1 || ok=0
row policy "PUT asking for SSE-KMS with the lab key" "written (lab key)" "$o" $ok
code=$(curl -s -o /dev/null -w '%{http_code}' "https://$MB.s3.$LAB22_REGION.amazonaws.com/lab22/kms.txt")
[ "$code" = 403 ] && ok=1 || ok=0; row policy "unsigned GET of an object" "403" "$code" $ok
code=$(curl -s -o /dev/null -w '%{http_code}' "$(aws s3 presign "s3://$MB/lab22/kms.txt" --expires-in 60 | sed 's#^https://#http://#')")
[ "$code" = 403 ] && ok=1 || ok=0; row policy "signed GET over plain HTTP" "403 (DenyNonTLS)" "$code" $ok
aws s3 rm "s3://$MB/lab22/" --recursive --only-show-errors

echo "════ 3. Recommended setup: overlays ${BASEOV[*]} aws-s3-sse, OTLP media extraction off ════"
export LAB22_OTEL_MEDIA=false; langfuse_on "${BASEOV[@]}" aws-s3-sse
envs=$(docker exec "$(lf_compose -- ps -q langfuse-web)" sh -c 'echo "${LANGFUSE_S3_EVENT_UPLOAD_SSE:-unset} ${LANGFUSE_S3_MEDIA_UPLOAD_SSE:-unset}"')
[ "$envs" = "aws:kms unset" ] && ok=1 || ok=0; row langfuse "SSE variables (event, media)" "aws:kms unset" "$envs" $ok
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "── 3a. Python SDK, LangfuseMedia (upload over the presigned PUT URL)"
send sdk "sdk-$T0"; SDK_TRACE=$(field TRACE_ID); SDK_SHA=$(field SHA256); SDK_MARK=$(field MARKER)
inp=$(ch_input "$SDK_TRACE"); o=$(inline_or_ref "$inp" "$SDK_MARK")
[ "$o" = "media reference" ] && ok=1 || ok=0; row sdk "ClickHouse input" "media reference" "$o" $ok
SDK_MID=$(media_id "$inp")
read -r st SDK_KEY <<<"$("${PSQL[@]}" -c "SELECT coalesce(upload_http_status::text,'null'), bucket_path FROM media WHERE id = '${SDK_MID:-none}'" | tr '|' ' ')"
[ "${st:-}" = 200 ] && ok=1 || ok=0; row sdk "media upload status (Postgres)" "200" "${st:-no media row}" $ok
o=$(lab_key "$MB" "${SDK_KEY:-missing}"); [ "$o" = "aws:kms lab-key True" ] && ok=1 || ok=0
row sdk "media object encryption" "aws:kms, lab key, bucket key" "${o:-no object}" $ok
echo "── 3b. Raw OTLP, base64 data URI, extraction off (Langfuse default)"
send otlp "otlp-off-$T0"; OFF_MARK=$(field MARKER); h=$(field HTTP)
inp=$(ch_input "$(field TRACE_ID)"); o=$(inline_or_ref "$inp" "$OFF_MARK")
[ "$o" = "base64 inline" ] && ok=1 || ok=0; row otlp-off "ClickHouse input (HTTP $h)" "base64 inline (nothing extracts it)" "$o" $ok

echo "════ 4. OTLP media extraction on (LAB22_OTEL_MEDIA=true) ════"
export LAB22_OTEL_MEDIA=true; langfuse_on "${BASEOV[@]}" aws-s3-sse
send otlp "otlp-on-$T0"; ON_MARK=$(field MARKER); h=$(field HTTP)
inp=$(ch_input "$(field TRACE_ID)"); o=$(inline_or_ref "$inp" "$ON_MARK")
[ "$o" = "media reference" ] && ok=1 || ok=0; row otlp-on "ClickHouse input (HTTP $h)" "media reference" "$o" $ok
ON_MID=$(media_id "$inp")
read -r st ON_KEY <<<"$("${PSQL[@]}" -c "SELECT coalesce(upload_http_status::text,'null'), bucket_path FROM media WHERE id = '${ON_MID:-none}'" | tr '|' ' ')"
o=$(lab_key "$MB" "${ON_KEY:-missing}"); [ "$o" = "aws:kms lab-key True" ] && ok=1 || ok=0
row otlp-on "media object encryption (worker upload)" "aws:kms, lab key, bucket key" "${o:-no object}" $ok
echo "── raw event objects written since $T0"
aws s3api list-objects-v2 --bucket "$LAB22_EVENT_BUCKET" --prefix "events/" \
  --query "Contents[?LastModified>='$T0'].Key" --output text | tr '\t' '\n' | grep -v '^None$' > "$WORK/events.txt" || true
n=0; nk=0; w_sdk=0; w_off=0; w_on=0
while read -r k; do
  [[ -z "$k" ]] && continue; n=$((n+1))
  [[ "$(lab_key "$LAB22_EVENT_BUCKET" "$k")" == "aws:kms lab-key True" ]] && nk=$((nk+1))
  aws s3 cp "s3://$LAB22_EVENT_BUCKET/$k" "$WORK/ev.json" --only-show-errors
  grep -q "$SDK_MARK" "$WORK/ev.json" && w_sdk=$((w_sdk+1)); grep -q "$OFF_MARK" "$WORK/ev.json" && w_off=$((w_off+1))
  grep -q "$ON_MARK" "$WORK/ev.json" && w_on=$((w_on+1))
done < "$WORK/events.txt"
[[ "$n" -ge 3 && "$nk" = "$n" ]] && ok=1 || ok=0; row events "raw event objects encrypted" "all aws:kms with the lab key" "$nk of $n" $ok
[ "$w_sdk" = 0 ] && ok=1 || ok=0; row events "SDK image bytes in raw events" "none (the SDK sent a reference)" "$w_sdk object(s)" $ok
[[ "$w_off" -ge 1 && "$w_on" -ge 1 ]] && ok=1 || ok=0
row events "OTLP image bytes in raw events" "present for both OTLP traces (raw payload kept as sent)" "off: $w_off, on: $w_on object(s)" $ok

echo "════ 5. Reading the image back (presigned GET, expiry $LAB22_MEDIA_URL_EXPIRY s) ════"
curl -fsS -m 30 -u "$LAB22_PK:$LAB22_SK" "$HOST/api/public/media/${SDK_MID:-none}" > "$WORK/media.json" || echo '{}' > "$WORK/media.json"
URL=$(jq -r '.url // empty' "$WORK/media.json")
exp=$({ grep -o 'X-Amz-Expires=[0-9]*' <<<"$URL" || true; } | cut -d= -f2); hosturl=$(sed -E 's#^https://([^/]+)/.*#\1#' <<<"$URL")
[[ "$exp" = "$LAB22_MEDIA_URL_EXPIRY" && "$hosturl" = "$MB.s3.$LAB22_REGION.amazonaws.com" ]] && ok=1 || ok=0
row read "presigned GET URL (public API)" "media bucket S3 host, X-Amz-Expires=$LAB22_MEDIA_URL_EXPIRY" "${hosturl/$MB/<media bucket>}, X-Amz-Expires=${exp:-none}" $ok
code=$(curl -s -o "$WORK/got.png" -w '%{http_code}' "${URL:-http://invalid}" || true); got=$( [ -s "$WORK/got.png" ] && shasum -a 256 "$WORK/got.png" | cut -d' ' -f1 || echo none)
[[ "$code" = 200 && "$got" = "$SDK_SHA" ]] && ok=1 || ok=0
row read "GET with the URL, no Langfuse login" "200, same SHA-256 as sent" "$code, sha match: $([ "$got" = "$SDK_SHA" ] && echo yes || echo no)" $ok
echo "  waiting $(( LAB22_MEDIA_URL_EXPIRY + 5 )) s for the URL to expire…"; sleep $(( LAB22_MEDIA_URL_EXPIRY + 5 ))
code=$(curl -s -o /dev/null -w '%{http_code}' "${URL:-http://invalid}" || true)
[ "$code" = 403 ] && ok=1 || ok=0; row read "same URL after expiry" "403" "$code" $ok

echo "════ 6. LANGFUSE_S3_MEDIA_UPLOAD_SSE set too (overlay aws-s3-media-sse) ════"
langfuse_on "${BASEOV[@]}" aws-s3-sse aws-s3-media-sse
send sdk "sdk-mediasse-$T0"; inp=$(ch_input "$(field TRACE_ID)"); mid=$(media_id "$inp")
st=$("${PSQL[@]}" -c "SELECT coalesce(upload_http_status::text,'null') FROM media WHERE id = '${mid:-none}'")
[ "$st" = 403 ] && ok=1 || ok=0; row media-sse "SDK media upload status" "403 (upload refused, image not stored)" "${st:-no media row}" $ok
# The same upload by hand: ask for a presigned PUT URL, then PUT the way the SDKs do, then with the signed SSE headers
send png "manual-$T0" "$WORK/m.png"; MSHA=$(field SHA256B64); MLEN=$(field LENGTH)
TRACE=$(openssl rand -hex 16)
curl -fsS -m 30 -u "$LAB22_PK:$LAB22_SK" -H 'Content-Type: application/json' -X POST "$HOST/api/public/media" \
  -d "$(jq -nc --arg t "$TRACE" --arg s "$MSHA" --argjson l "$MLEN" '{traceId:$t, contentType:"image/png", contentLength:$l, sha256Hash:$s, field:"input"}')" > "$WORK/up.json"
UP=$(jq -r '.uploadUrl // empty' "$WORK/up.json")
sh=$(python3 -c 'import sys,urllib.parse as u; q=u.parse_qs(u.urlsplit(sys.argv[1]).query); print(q.get("X-Amz-SignedHeaders",["none"])[0])' "${UP:-http://x/?}")
[[ "$sh" == *x-amz-server-side-encryption* ]] && ok=1 || ok=0
row media-sse "signed headers of the presigned PUT URL" "include x-amz-server-side-encryption(-aws-kms-key-id)" "$sh" $ok
code=$(curl -s -o "$WORK/put1.xml" -w '%{http_code}' -X PUT "$UP" -H 'Content-Type: image/png' -H "x-amz-checksum-sha256: $MSHA" --data-binary @"$WORK/m.png")
d=$(denied "$WORK/put1.xml"); [[ "$code" = 403 ]] && ok=1 || ok=0
row media-sse "PUT with the SDKs' headers" "403" "$code ${d:-}" $ok
code=$(curl -s -o "$WORK/put2.xml" -w '%{http_code}' -X PUT "$UP" -H 'Content-Type: image/png' -H "x-amz-checksum-sha256: $MSHA" \
  -H 'x-amz-server-side-encryption: aws:kms' -H "x-amz-server-side-encryption-aws-kms-key-id: $LAB22_KMS_KEY_ARN" --data-binary @"$WORK/m.png")
[[ "$code" = 200 ]] && ok=1 || ok=0; row media-sse "same PUT plus the two SSE headers" "200" "$code $(denied "$WORK/put2.xml")" $ok
send otlp "otlp-mediasse-$T0"; mark=$(field MARKER); inp=$(ch_input "$(field TRACE_ID)"); mid=$(media_id "$inp")
key=$("${PSQL[@]}" -c "SELECT bucket_path FROM media WHERE id = '${mid:-none}'"); o=$(lab_key "$MB" "${key:-missing}")
[[ "$(inline_or_ref "$inp" "$mark")" = "media reference" && "$o" = "aws:kms lab-key True" ]] && ok=1 || ok=0
row media-sse "OTLP extraction (worker upload, no presigned URL)" "media reference, object aws:kms lab key" "$(inline_or_ref "$inp" "$mark"), ${o:-no object}" $ok

echo "════ 7. Back to the recommended setup ════"
langfuse_on "${BASEOV[@]}" aws-s3-sse
echo "  web + worker on ${BASEOV[*]} aws-s3-sse (LAB22_OTEL_MEDIA=true); --cleanup removes the AWS resources and returns to MinIO"

echo
echo "| Area | Check | Expected | Observed | Result |"
echo "|---|---|---|---|---|"
awk -F'\t' '{printf "| %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5}' "$ROWS"
echo
echo "PASS $(grep -c $'\tPASS$' "$ROWS" || true) · FAIL $FAILS"
exit $(( FAILS > 0 ))
