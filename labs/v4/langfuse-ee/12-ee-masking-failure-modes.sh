#!/usr/bin/env bash
# 12-ee-masking-failure-modes.sh — what happens to a secret when the masking callback fails?
#
# Lab 08 shows the happy path. This lab breaks the callback and watches the worker:
#   S0  healthy /mask                    positive control: the secret is masked
#   S1  callback down                    FAIL_CLOSED=false  -> raw secret stored (1a closed port, 1b container stopped)
#   S2  /mask-slow (2 s, timeout 500 ms) FAIL_CLOSED=false  -> raw secret stored
#   S3  callback down                    FAIL_CLOSED=true   -> event dropped (3a closed port, 3b container stopped)
#   S4  /mask-slow                       FAIL_CLOSED=true   -> event dropped
#   S5  /mask-500                        FAIL_CLOSED=false  -> raw, then FAIL_CLOSED=true -> dropped
#   2c  per-project rule                 MASK_STRICT_PROJECT_IDS=<A>: an account number is redacted for A only
#   2d  legacy path                      POST /api/public/ingestion: does it reach masking?
#   2e  S3 raw copy                      the worker downloads the raw payload from the event bucket; is it still there?
#
# "Dropped" is shown by the worker log line (with the S3 fileKey), by the S3 object still being there, and by
# waiting at least as long as the slowest raw-stored scenario took to appear in ClickHouse — not by absence alone.
# Every scenario sets FAIL_CLOSED and TIMEOUT_MS explicitly: the repository overlay defaults are true / 2000 ms,
# the worker's own defaults are false / 500 ms.
#
# Exits non-zero unless every check printed PASS. The run takes ~4 minutes (measured 2026-10-12).
# Requires: EE overlay up (EE=1 _base/bin/up.sh v4), `jq`, `curl`, `aws` (MinIO S3 API on the host),
# .venv-v4 with _base/v4/requirements.txt. Ends with the worker back on the overlay defaults.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

for c in jq curl aws; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
PY="$BASE_DIR/../.venv-v4/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
ADMIN="Authorization: Bearer ${ADMIN_API_KEY:?set ADMIN_API_KEY in _base/.env}"
CH_USER="${CLICKHOUSE_USER:-clickhouse}"
CH_PASSWORD="${CLICKHOUSE_PASSWORD:-clickhouse}"
WORKER="$LF_PROJECT-langfuse-worker-1"
SIDECAR="$LF_PROJECT-masking-1"
OVERLAY_URL="http://masking:3100/mask"
TS=$(date +%s)
ACCT=$(printf '110-23-%06d' $((TS % 1000000)))
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
ROWS="$WORK/rows.tsv"; : > "$ROWS"; FAILS=0
SLOWEST_RAW=10        # seconds the slowest raw-stored scenario took to appear (floor 10), set by run_scenario
MAX_WAIT=90           # ClickHouse polling limit per scenario

ch() { lf_compose -- exec -T clickhouse clickhouse-client -u "$CH_USER" --password "$CH_PASSWORD" "$@"; }
pass() { echo "PASS  $1: $2"; }
fail() { echo "FAIL  $1: $2"; FAILS=$((FAILS + 1)); }
# expect NAME OBSERVED WANTED — string equality
expect() { if [ "$2" = "$3" ]; then pass "$1" "$2"; else fail "$1" "observed '$2', wanted '$3'"; fi; }
# row <id> <callback> <fail_closed> <timeout_ms> <expected> <observed> <ok:0|1>
row() {
  local res=PASS; [ "$7" = 1 ] || { res=FAIL; FAILS=$((FAILS + 1)); }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$res" >> "$ROWS"
  echo "  $res  $1 | $2 | FAIL_CLOSED=$3 | TIMEOUT_MS=$4 | expected: $5 | observed: $6"
}

# wait_worker — the worker's own health endpoint (published on 127.0.0.1:3030)
wait_worker() {
  for _ in $(seq 1 40); do
    curl -fsS -m 3 http://127.0.0.1:3030/api/health >/dev/null 2>&1 && { sleep 3; return 0; }
    sleep 2
  done
  echo "✗ worker did not become healthy"; exit 1
}
# set_worker URL FAIL_CLOSED TIMEOUT_MS — recreate ONLY the worker with this masking config (--no-deps: do not
# restart a stopped sidecar). A fresh container also means a fresh log, so each scenario reads only its own lines.
set_worker() {
  LANGFUSE_INGESTION_MASKING_CALLBACK_URL="$1" LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED="$2" \
  LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS="$3" \
    lf_compose ee masking -- up -d --no-deps --force-recreate langfuse-worker >/dev/null 2>&1
  wait_worker
  local cfg; cfg=$(docker exec "$WORKER" env | grep -E '^LANGFUSE_INGESTION_MASKING_(CALLBACK_URL|CALLBACK_FAIL_CLOSED|CALLBACK_TIMEOUT_MS|MAX_RETRIES)=' | tr '\n' ' ')
  echo "  worker env: ${cfg}(MAX_RETRIES unset = worker default)"
}
# ch_counts PROJECT TRACE SECRET → "rows<TAB>raw_secret<TAB>redacted_key<TAB>raw_account<TAB>redacted_account"
ch_counts() {
  ch -q "SELECT count(), countIf(position(r,'$3')>0), countIf(position(r,'[REDACTED_API_KEY]')>0),
                countIf(position(r,'$ACCT')>0), countIf(position(r,'[REDACTED_ACCOUNT]')>0)
         FROM (SELECT toString(tuple(*)) AS r FROM events_full WHERE project_id='$1' AND trace_id='$2')"
}
# send PROJECT_VAR SECRET → sets TRACE_ID (the project's keys are in PUB_<v>/SEC_<v>)
send() {
  local pv="PUB_$1" sv="SEC_$1" out
  out=$(FM_PUBLIC_KEY="${!pv}" FM_SECRET_KEY="${!sv}" LANGFUSE_HOST="$HOST" "$PY" 12-send-marker.py "$2" "$ACCT")
  TRACE_ID=$(echo "$out" | awk '/^TRACE_ID/ {print $2}')
  [[ -n "$TRACE_ID" ]] || { echo "✗ send failed"; exit 1; }
}
# poll_rows PROJECT TRACE SECRET LIMIT → sets APPEAR (seconds until the first row, or -1) and COUNTS
poll_rows() {
  local t0=$SECONDS
  APPEAR=-1; COUNTS=""
  while (( SECONDS - t0 < $4 )); do
    COUNTS=$(ch_counts "$1" "$2" "$3")
    if [[ "${COUNTS%%$'\t'*}" -gt 0 ]]; then APPEAR=$((SECONDS - t0)); return 0; fi
    sleep 2
  done
}
# worker_lines PROJECT → the warn lines this scenario's worker wrote about masking for that project
worker_lines() { docker logs "$WORKER" 2>&1 | grep -E 'Ingestion masking callback failed|Dropping OTEL event' | grep "$1" || true; }

# run_scenario ID LABEL URL FAIL_CLOSED TIMEOUT_MS EXPECT(masked|raw|dropped)
run_scenario() {
  local id="$1" label="$2" url="$3" fc="$4" to="$5" want="$6" secret obs lines attempts dropline filekey
  secret="sk-MODE${id}-${TS}abcdef"
  echo "── $id: $label (FAIL_CLOSED=$fc, TIMEOUT_MS=$to, expect $want) ──"
  set_worker "$url" "$fc" "$to"
  send A "$secret"
  if [[ "$want" = dropped ]]; then
    # Evidence besides absence: wait for the worker's "Dropping" line, then wait as long as the slowest raw scenario
    # needed to appear, and only then read ClickHouse.
    for _ in $(seq 1 45); do [[ -n "$(worker_lines "$PID_A" | grep 'Dropping OTEL' || true)" ]] && break; sleep 2; done
    sleep "$SLOWEST_RAW"
    COUNTS=$(ch_counts "$PID_A" "$TRACE_ID" "$secret"); APPEAR=-1
  else
    poll_rows "$PID_A" "$TRACE_ID" "$secret" "$MAX_WAIT"
  fi
  local rows raw red
  rows=$(echo "$COUNTS" | cut -f1); raw=$(echo "$COUNTS" | cut -f2); red=$(echo "$COUNTS" | cut -f3)
  lines=$(worker_lines "$PID_A")
  attempts=$(echo "$lines" | grep -c 'callback failed' || true)
  dropline=$(echo "$lines" | grep 'Dropping OTEL' | head -1 || true)
  filekey=$(echo "$dropline" | grep -o '"fileKey":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  if   [[ "$rows" -gt 0 && "$raw" -gt 0 ]]; then obs=raw
  elif [[ "$rows" -gt 0 && "$red" -gt 0 && "$raw" -eq 0 ]]; then obs=masked
  elif [[ "$rows" -eq 0 && -n "$dropline" ]]; then obs=dropped
  else obs="none(rows=$rows raw=$raw redacted=$red, no drop line)"; fi
  echo "  events_full rows=$rows raw_secret_rows=$raw redacted_key_rows=$red account_raw_rows=$(echo "$COUNTS" | cut -f4); first row after ${APPEAR}s"
  echo "  worker warn lines (attempt counts: $attempts):"
  echo "$lines" | sed 's/^/    /' | cut -c1-420 | sed "s/$secret/<secret>/g"
  local ok=0; [[ "$obs" = "$want" ]] && ok=1
  # 'dropped' needs the fileKey and the S3 object still being there (replayable raw copy)
  if [[ "$want" = dropped ]]; then
    if [[ -n "$filekey" ]] && s3 s3api head-object --bucket "${LANGFUSE_S3_EVENT_UPLOAD_BUCKET:-langfuse}" --key "$filekey" >/dev/null 2>&1; then
      echo "  fileKey in the Dropping line: $filekey  (object still in S3: yes)"
    else ok=0; echo "  fileKey in the Dropping line: '${filekey:-<none>}'  (object in S3: NOT confirmed)"; fi
  fi
  if [[ "$want" = raw && "$APPEAR" -ge 0 && "$APPEAR" -gt "$SLOWEST_RAW" ]]; then SLOWEST_RAW=$APPEAR; fi
  row "$id" "$label" "$fc" "$to" "$want" "$obs" "$ok"
}

# S3 access through the MinIO S3 API published on the host (credentials from _base/.env, never printed)
s3() {
  AWS_ACCESS_KEY_ID="${LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID:-${MINIO_ROOT_USER:-minio}}" \
  AWS_SECRET_ACCESS_KEY="${LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY:-${MINIO_ROOT_PASSWORD:-miniosecret}}" \
  AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true AWS_PAGER="" \
    aws --endpoint-url http://localhost:9090 "$@"
}

echo "════ 0. Setup: org, projects A and B, API keys ════"
ORG_ID=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations" -H "$ADMIN" -H "Content-Type: application/json" \
  -d "{\"name\":\"mask-modes-$TS\"}" | jq -r .id)
ORG_KEY=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations/$ORG_ID/apiKeys" -H "$ADMIN" \
  -H "Content-Type: application/json" -d '{"note":"lab 12"}')
ORG_AUTH="$(echo "$ORG_KEY" | jq -r .publicKey):$(echo "$ORG_KEY" | jq -r .secretKey)"
orgcurl() { curl -fsS -m 30 -u "$ORG_AUTH" "$@"; }
for P in A B; do
  PID=$(orgcurl -X POST "$HOST/api/public/projects" -H "Content-Type: application/json" \
    -d "{\"name\":\"mask-modes-$P-$TS\",\"retention\":0}" | jq -r .id)
  PK=$(orgcurl -X POST "$HOST/api/public/projects/$PID/apiKeys" -H "Content-Type: application/json" -d '{"note":"lab 12"}')
  eval "PID_$P=$PID; PUB_$P=$(echo "$PK" | jq -r .publicKey); SEC_$P=$(echo "$PK" | jq -r .secretKey)"
done
echo "  org $ORG_ID  project A $PID_A  project B $PID_B"
echo "  account number used in every payload: $ACCT (fabricated)"
echo "  worker image: $(docker inspect -f '{{.Config.Image}}' "$WORKER")   sidecar image: $(docker inspect -f '{{.Config.Image}}' "$SIDECAR")"
lf_compose ee masking -- up -d masking >/dev/null 2>&1
for _ in $(seq 1 20); do [[ "$(docker inspect -f '{{.State.Health.Status}}' "$SIDECAR")" = healthy ]] && break; sleep 2; done

echo "════ 1. Failure modes (one trace per scenario, worker recreated with the scenario env) ════"
run_scenario S0  "healthy /mask"                 "$OVERLAY_URL"             false 500 masked
run_scenario S2  "/mask-slow (2 s)"              "http://masking:3100/mask-slow" false 500 raw
run_scenario S5a "/mask-500"                     "http://masking:3100/mask-500"  false 500 raw
run_scenario S1a "down: closed port"             "http://masking:3999/mask"      false 500 raw
echo "  slowest raw-stored scenario appeared after ${SLOWEST_RAW}s (floor 10 s) — dropped scenarios wait at least that long"
run_scenario S3a "down: closed port"             "http://masking:3999/mask"      true  500 dropped
run_scenario S4  "/mask-slow (2 s)"              "http://masking:3100/mask-slow" true  500 dropped
run_scenario S5b "/mask-500"                     "http://masking:3100/mask-500"  true  500 dropped
lf_compose ee masking -- stop masking >/dev/null 2>&1
echo "  (sidecar container stopped: $(docker inspect -f '{{.State.Status}}' "$SIDECAR"))"
run_scenario S1b "down: sidecar stopped"         "$OVERLAY_URL"             false 500 raw
run_scenario S3b "down: sidecar stopped"         "$OVERLAY_URL"             true  500 dropped
lf_compose ee masking -- up -d masking >/dev/null 2>&1
for _ in $(seq 1 20); do [[ "$(docker inspect -f '{{.State.Health.Status}}' "$SIDECAR")" = healthy ]] && break; sleep 2; done

echo "════ 2c. Per-project rule: MASK_STRICT_PROJECT_IDS=<A> adds [REDACTED_ACCOUNT] for A only ════"
MASK_STRICT_PROJECT_IDS="$PID_A" lf_compose ee masking -- up -d --force-recreate masking >/dev/null 2>&1
for _ in $(seq 1 20); do [[ "$(docker inspect -f '{{.State.Health.Status}}' "$SIDECAR")" = healthy ]] && break; sleep 2; done
set_worker "$OVERLAY_URL" true 2000
SEC2C="sk-MODE2c-${TS}abcdef"
send A "$SEC2C"; TA="$TRACE_ID"; send B "$SEC2C"; TB="$TRACE_ID"
poll_rows "$PID_A" "$TA" "$SEC2C" "$MAX_WAIT"; CA="$COUNTS"
poll_rows "$PID_B" "$TB" "$SEC2C" "$MAX_WAIT"; CB="$COUNTS"
echo "  project A rows/raw_secret/redacted_key/raw_account/redacted_account = $(echo "$CA" | tr '\t' '/')"
echo "  project B rows/raw_secret/redacted_key/raw_account/redacted_account = $(echo "$CB" | tr '\t' '/')"
expect "2c A: rows landed"                         "$([ "$(echo "$CA" | cut -f1)" -gt 0 ] && echo yes || echo no)" yes
expect "2c A: [REDACTED_ACCOUNT] present"          "$([ "$(echo "$CA" | cut -f5)" -gt 0 ] && echo yes || echo no)" yes
expect "2c A: raw account rows"                    "$(echo "$CA" | cut -f4)" 0
expect "2c A: sk- redacted, raw secret rows"       "$(echo "$CA" | cut -f2)" 0
expect "2c B: rows landed"                         "$([ "$(echo "$CB" | cut -f1)" -gt 0 ] && echo yes || echo no)" yes
expect "2c B: raw account kept (positive control)" "$([ "$(echo "$CB" | cut -f4)" -gt 0 ] && echo yes || echo no)" yes
expect "2c B: [REDACTED_ACCOUNT] rows"             "$(echo "$CB" | cut -f5)" 0
expect "2c B: sk- still redacted, raw secret rows" "$(echo "$CB" | cut -f2)" 0
expect "2c B: [REDACTED_API_KEY] present"          "$([ "$(echo "$CB" | cut -f3)" -gt 0 ] && echo yes || echo no)" yes
echo "  sidecar log lines for both projects:"
docker logs "$SIDECAR" 2>&1 | grep -E "project=($PID_A|$PID_B) " | sed 's/^/    /'
SIDE_A=$(docker logs "$SIDECAR" 2>&1 | grep -c "project=$PID_A path=/mask rules=base+strict" || true)
SIDE_B=$(docker logs "$SIDECAR" 2>&1 | grep -c "project=$PID_B path=/mask rules=base redactions" || true)
expect "2c sidecar logged A with rules=base+strict" "$SIDE_A" 1
expect "2c sidecar logged B with rules=base"        "$SIDE_B" 1

echo "════ 2d. Legacy path: POST /api/public/ingestion with healthy masking, FAIL_CLOSED=true ════"
# Positive control for the search below: S0 above (same secret pattern via OTLP) is masked, S1a/S1b/S2/S5a raw.
ISO=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
SIDE_BEFORE=$(docker logs "$SIDECAR" 2>&1 | grep -c "project=$PID_A " || true)
LEG_TYPES="trace-create span-create generation-create event-create score-create"
LEG_ACCEPTED=""
LEG_TID=$(openssl rand -hex 16)
for T in $LEG_TYPES; do
  M="sk-LEGACY-${T%%-*}-${TS}abcdef"; EID=$(openssl rand -hex 16); OID=$(openssl rand -hex 8)
  case "$T" in
    trace-create)      BODY=$(jq -nc --arg id "$LEG_TID" --arg m "$M" '{id:$id,name:"legacy-trace",input:$m}') ;;
    span-create)       BODY=$(jq -nc --arg id "$OID" --arg t "$LEG_TID" --arg m "$M" --arg ts "$ISO" '{id:$id,traceId:$t,name:"legacy-span",startTime:$ts,input:$m}') ;;
    generation-create) BODY=$(jq -nc --arg id "$OID" --arg t "$LEG_TID" --arg m "$M" --arg ts "$ISO" '{id:$id,traceId:$t,name:"legacy-gen",model:"demo-model",startTime:$ts,input:$m}') ;;
    event-create)      BODY=$(jq -nc --arg id "$OID" --arg t "$LEG_TID" --arg m "$M" --arg ts "$ISO" '{id:$id,traceId:$t,name:"legacy-event",startTime:$ts,input:$m}') ;;
    score-create)      BODY=$(jq -nc --arg id "$OID" --arg t "$LEG_TID" --arg m "$M" '{id:$id,traceId:$t,name:"legacy-score",value:1,comment:$m}') ;;
  esac
  REQ=$(jq -nc --arg id "$EID" --arg ty "$T" --arg ts "$ISO" --argjson b "$BODY" '{batch:[{id:$id,type:$ty,timestamp:$ts,body:$b}]}')
  RESP=$(curl -sS -m 30 -o "$WORK/leg.json" -w '%{http_code}' -u "$PUB_A:$SEC_A" -X POST "$HOST/api/public/ingestion" \
    -H "Content-Type: application/json" -d "$REQ")
  NS=$(jq -r '(.successes // []) | length' "$WORK/leg.json" 2>/dev/null || echo "?")
  NE=$(jq -r '(.errors // []) | length' "$WORK/leg.json" 2>/dev/null || echo "?")
  ERR=$(jq -rc '(.errors // [])[0].error // (.errors // [])[0].message // .message // .' "$WORK/leg.json" 2>/dev/null | cut -c1-260 | sed "s/$M/<secret>/g")
  echo "  $T: HTTP $RESP successes=$NS errors=$NE ${ERR:+first error/body: $ERR}"
  if [[ "$NS" = 1 ]]; then LEG_ACCEPTED="$LEG_ACCEPTED $T"; fi
  eval "LEGST_${T%%-*}=$RESP; LEGNS_${T%%-*}=$NS; LEGM_${T%%-*}=$M"
done
echo "  accepted legacy event types:${LEG_ACCEPTED:- none}"
LEG_TABLES="events_full events_core traces observations scores"
leg_find() {   # leg_find MARKER → "table:count ..." over every table that can hold the event, project A only
  local out="" t n
  for t in $LEG_TABLES; do
    n=$(ch -q "SELECT count() FROM $t WHERE project_id='$PID_A' AND position(toString(tuple(*)),'$1')>0" 2>/dev/null || echo err)
    out="$out $t:$n"
  done
  echo "$out"
}
for T in $LEG_TYPES; do
  K="${T%%-*}"; M=$(eval echo "\$LEGM_$K"); NS=$(eval echo "\$LEGNS_$K")
  FOUND=""
  if [[ "$NS" = 1 ]]; then
    for _ in $(seq 1 30); do FOUND=$(leg_find "$M"); echo "$FOUND" | grep -qE ':[1-9]' && break; sleep 2; done
    if echo "$FOUND" | grep -qE ':[1-9]'; then
      echo "  $T accepted -> raw secret found in:$FOUND"
      expect "2d $T accepted: raw secret reaches ClickHouse (legacy path bypasses masking)" "yes" yes
    else
      fail "2d $T accepted but the raw secret is in no table after 60 s" "$FOUND"
    fi
  else
    FOUND=$(leg_find "$M")
    echo "  $T rejected -> search over the same tables:$FOUND"
    if echo "$FOUND" | grep -qE ':[1-9]'; then fail "2d $T rejected but found in ClickHouse" "$FOUND"
    else pass "2d $T rejected (HTTP $(eval echo "\$LEGST_$K")), nothing stored" "$FOUND"; fi
  fi
done

SIDE_AFTER=$(docker logs "$SIDECAR" 2>&1 | grep -c "project=$PID_A " || true)
expect "2d sidecar received no request for project A during the legacy calls (log lines before/after: $SIDE_BEFORE/$SIDE_AFTER)" "$SIDE_AFTER" "$SIDE_BEFORE"

echo "════ 2e. The raw payload in the S3 event bucket ════"
BUCKET="${LANGFUSE_S3_EVENT_UPLOAD_BUCKET:-langfuse}"
echo "  bucket top-level prefixes: $(s3 s3 ls "s3://$BUCKET/" | awk '{print $2}' | tr '\n' ' ')"
# Two layouts: OTLP raw payloads at events/otel/<project>/<yyyy>/<mm>/<dd>/<hh>/<mm>/<uuid>.json (the worker's fileKey),
# legacy events at events/<project>/<type>/<entity id>/<event id>.json.
mkdir -p "$WORK/s3"
for P in A B; do
  PV="PID_$P"
  s3 s3 cp --recursive --only-show-errors "s3://$BUCKET/events/otel/${!PV}/" "$WORK/s3/otel-$P/" || true
  s3 s3 cp --recursive --only-show-errors "s3://$BUCKET/events/${!PV}/" "$WORK/s3/legacy-$P/" || true
done
echo "  objects: events/otel/<A>/ $(find "$WORK/s3/otel-A" -type f 2>/dev/null | wc -l | tr -d ' ')  events/otel/<B>/ $(find "$WORK/s3/otel-B" -type f 2>/dev/null | wc -l | tr -d ' ')  events/<A>/ $(find "$WORK/s3/legacy-A" -type f 2>/dev/null | wc -l | tr -d ' ')"
echo "  key layout (project ids replaced by <A>/<B>):"
s3 s3api list-objects-v2 --bucket "$BUCKET" --prefix "events/" --query 'Contents[].Key' --output text | tr '\t' '\n' \
  | grep -E "$PID_A|$PID_B" | sed "s/$PID_A/<A>/; s/$PID_B/<B>/" | awk -F/ '{n=$0; sub(/[0-9a-f-]{20,}\.json$/, "<uuid>.json", n); sub(/[0-9a-f]{12,}/, "<id>", n); print n}' | sort | uniq -c | sed 's/^/    /' || true
S0_SECRET="sk-MODES0-${TS}abcdef"
S0_FILES=$( (grep -rl -- "$S0_SECRET" "$WORK/s3" 2>/dev/null || true) | sed "s|$WORK/s3/||")
echo "  object(s) holding the S0 raw secret (healthy masking, masked in ClickHouse):"
echo "${S0_FILES:-    <none>}" | sed 's/^/    /'
expect "2e S0: raw secret present in S3 although ClickHouse holds the masked copy" "$([ -n "$S0_FILES" ] && echo yes || echo no)" yes
S0_RED=$( (grep -rl -- "REDACTED_" "$WORK/s3" 2>/dev/null || true) | wc -l | tr -d ' ')
expect "2e no masked copy written back to S3 (objects containing REDACTED_ under both projects)" "$S0_RED" 0
for T in $LEG_TYPES; do
  K="${T%%-*}"; M=$(eval echo "\$LEGM_$K"); NS=$(eval echo "\$LEGNS_$K")
  [[ "$NS" = 1 ]] || { echo "  legacy $T was rejected: no S3 object expected"; continue; }
  F=$( (grep -rl -- "$M" "$WORK/s3" 2>/dev/null || true) | sed "s|$WORK/s3/||")
  echo "  legacy $T object(s) with the raw secret: ${F:-<none>}"
  expect "2e legacy $T: raw copy in S3" "$([ -n "$F" ] && echo yes || echo no)" yes
done
# Dropped events (S3a ...) keep their raw object too: checked per scenario above with head-object on the fileKey.
S1_FILES=$( (grep -rl -- "sk-MODES1a-${TS}abcdef" "$WORK/s3" 2>/dev/null || true) | wc -l | tr -d ' ')
expect "2e S1a (raw stored in ClickHouse): its S3 object count" "$S1_FILES" 1

echo "════ 3. Restore: worker back on the overlay defaults, sidecar running ════"
lf_compose ee masking -- up -d >/dev/null 2>&1
wait_worker
docker exec "$WORKER" env | grep -E '^LANGFUSE_INGESTION_MASKING_CALLBACK_(URL|FAIL_CLOSED|TIMEOUT_MS)=' | sed 's/^/  /'
expect "sidecar state" "$(docker inspect -f '{{.State.Status}}/{{.State.Health.Status}}' "$SIDECAR")" running/healthy
expect "worker FAIL_CLOSED is the overlay default" "$(docker exec "$WORKER" printenv LANGFUSE_INGESTION_MASKING_CALLBACK_FAIL_CLOSED)" true
expect "worker TIMEOUT_MS is the overlay default"  "$(docker exec "$WORKER" printenv LANGFUSE_INGESTION_MASKING_CALLBACK_TIMEOUT_MS)" 2000
expect "sidecar has no strict project left"        "$(docker exec "$SIDECAR" printenv MASK_STRICT_PROJECT_IDS)" ""

echo
echo "════ Scenario table ════"
printf '%-5s| %-24s| %-12s| %-10s| %-9s| %-10s| %s\n' id callback FAIL_CLOSED TIMEOUT_MS expected observed result
while IFS=$'\t' read -r a b c d e f g; do
  printf '%-5s| %-24s| %-12s| %-10s| %-9s| %-10s| %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g"
done < "$ROWS"
echo
if [[ "$FAILS" -eq 0 ]]; then echo "✅ every check printed PASS"; else echo "✗ $FAILS check(s) FAILED"; exit 1; fi
