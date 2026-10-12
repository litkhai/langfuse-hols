#!/usr/bin/env bash
# 14-field-encryption.sh — client-side field encryption with the SDK's `mask_otel_spans` hook, end to end.
#
#   setup   new org + projects A and B (admin API, as in 06), one AES-256 key per project in
#           _base/.env.field-keys (mode 600, gitignored; keys are never printed)
#   send    14-field-encryption.py: 2 hook traces (input + metadata.account_no encrypted, output plaintext)
#           and 1 control trace without the hook (same markers + "-CTRL")
#   check   ClickHouse: no plaintext of the encrypted fields in any table that stores input/metadata, the control
#           trace IS found in plaintext (positive control); the public API returns ciphertext; 14-decrypt-fields.py
#           decrypts with the project's key and fails with the other project's key
#   search  the UI's trace-table content search (tRPC) finds nothing for the encrypted input, finds the
#           control, and still finds the plaintext output
#   judge   what an LLM-as-a-judge `{{input}}` variable resolves to (no model is called)
#
# Exits non-zero unless every check printed PASS. No model API is called.
# Requires: EE overlay up (EE=1 _base/bin/up.sh v4), `jq`, `curl`, .venv-v4 with _base/v4/requirements.txt.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "✗ please install jq"; exit 1; }
PY="$BASE_DIR/../.venv-v4/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
ADMIN="Authorization: Bearer ${ADMIN_API_KEY:?set ADMIN_API_KEY in _base/.env}"
CH_USER="${CLICKHOUSE_USER:-clickhouse}"
CH_PASSWORD="${CLICKHOUSE_PASSWORD:-clickhouse}"
KEYS_FILE="$BASE_DIR/.env.field-keys"
TS=$(date +%s)
FAILS=0
ch() { lf_compose -- exec -T clickhouse clickhouse-client -u "$CH_USER" --password "$CH_PASSWORD" "$@"; }
pass() { echo "PASS  $1: $2"; }
fail() { echo "FAIL  $1: $2"; FAILS=$((FAILS + 1)); }
# expect NAME OBSERVED PREDICATE(op, wanted) — e.g. expect "rows" 3 -eq 3
expect() { if [ "$2" "$3" "$4" ]; then pass "$1" "$2"; else fail "$1" "$2 (wanted $3 $4)"; fi; }

echo "════ 1. Setup: org, projects A and B, API keys, one AES-256 key per project ════"
ORG_ID=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations" -H "$ADMIN" -H "Content-Type: application/json" \
  -d "{\"name\":\"field-enc-$TS\"}" | jq -r .id)
ORG_KEY=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations/$ORG_ID/apiKeys" -H "$ADMIN" \
  -H "Content-Type: application/json" -d '{"note":"lab 14"}')
ORG_AUTH="$(echo "$ORG_KEY" | jq -r .publicKey):$(echo "$ORG_KEY" | jq -r .secretKey)"
orgcurl() { curl -fsS -m 30 -u "$ORG_AUTH" "$@"; }
umask 077; touch "$KEYS_FILE"; chmod 600 "$KEYS_FILE"
git -C "$BASE_DIR" check-ignore -q "$KEYS_FILE" || { echo "✗ $KEYS_FILE is not gitignored"; exit 1; }
for P in A B; do
  PID=$(orgcurl -X POST "$HOST/api/public/projects" -H "Content-Type: application/json" \
    -d "{\"name\":\"field-enc-$P-$TS\",\"retention\":0}" | jq -r .id)
  PK=$(orgcurl -X POST "$HOST/api/public/projects/$PID/apiKeys" -H "Content-Type: application/json" -d '{"note":"lab 14"}')
  eval "PID_$P=$PID; PUB_$P=$(echo "$PK" | jq -r .publicKey); SEC_$P=$(echo "$PK" | jq -r .secretKey)"
  # 32 random bytes, base64url; appended to the file, never echoed.
  printf 'FIELD_KEY_%s=%s\n' "$PID" "$("$PY" -c 'import base64,secrets;print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())')" >> "$KEYS_FILE"
done
echo "  org $ORG_ID  project A $PID_A  project B $PID_B"
echo "  AES keys: $(grep -c "^FIELD_KEY_\($PID_A\|$PID_B\)=" "$KEYS_FILE") written to _base/.env.field-keys, mode $(stat -f %Lp "$KEYS_FILE" 2>/dev/null || stat -c %a "$KEYS_FILE")"
export FE_PUBLIC_KEY="$PUB_A" FE_SECRET_KEY="$SEC_A" LANGFUSE_HOST="$HOST"

echo "════ 2. Send: 2 traces with the hook, 1 control trace without ════"
HOOK_OUT=$("$PY" 14-field-encryption.py hook "$PID_A" "$TS" 2)
echo "$HOOK_OUT" | grep -v '^TRACE_ID'
HOOK_IDS=($(echo "$HOOK_OUT" | awk '/^TRACE_ID/ {print $2}'))
CTRL_ID=$("$PY" 14-field-encryption.py control "$PID_A" "$TS" | awk '/^TRACE_ID/ {print $2}')
echo "  hook traces: ${HOOK_IDS[*]}"; echo "  control trace: $CTRL_ID"

echo "════ 3. ClickHouse: plaintext of the encrypted fields must be absent, the control must be present ════"
IN_MARK="ENCMARK-IN-$TS"; OUT_MARK="ENCMARK-OUT-$TS"; ACCT=$(printf '110-23-%06d' $((TS % 1000000)))
HOOK_LIST="'${HOOK_IDS[0]}','${HOOK_IDS[1]}'"
# Wait for the worker to land all 3 traces (6 observations) in events_full.
for _ in $(seq 1 30); do
  N=$(ch -q "SELECT count() FROM events_full WHERE project_id='$PID_A' AND trace_id IN ($HOOK_LIST,'$CTRL_ID')")
  [[ "$N" -ge 6 ]] && break; sleep 4
done
echo "  events_full rows for the 3 traces: $N (expect 6 = 3 traces x 2 observations)"
# Every v4 table with project_id that stores input/metadata. The whole row is searched, not only input/metadata:
# toString(tuple(*)) also covers metadata maps/arrays, the legacy-looking columns and anything else.
for T in events_full events_core events_core_mv traces observations observations_pid_tid_sorting observations_batch_staging; do
  TC=trace_id; [[ "$T" == traces ]] && TC=id
  ROW=$(ch -q "SELECT countIf($TC IN ($HOOK_LIST)),
       countIf($TC IN ($HOOK_LIST) AND position(r,'$IN_MARK')>0), countIf($TC IN ($HOOK_LIST) AND position(r,'$ACCT')>0),
       countIf($TC IN ($HOOK_LIST) AND position(r,'enc:v1:')>0),
       countIf($TC='$CTRL_ID'), countIf($TC='$CTRL_ID' AND position(r,'$IN_MARK-CTRL')>0), countIf($TC='$CTRL_ID' AND position(r,'$ACCT-CTRL')>0),
       countIf($TC IN ($HOOK_LIST) AND position(r,'$OUT_MARK')>0)
     FROM (SELECT $TC, toString(tuple(*)) AS r FROM $T WHERE project_id='$PID_A') FORMAT TSV")
  read -r H_ROWS H_IN H_ACCT H_ENC C_ROWS C_IN C_ACCT H_OUT <<<"$ROW"
  if [[ "$H_ROWS" -eq 0 && "$C_ROWS" -eq 0 ]]; then
    if [[ "$T" == events_full ]]; then fail "$T has rows of this run" "0"; else echo "INFO  $T: no rows of this run (table is not written by this stack) - nothing to check"; fi
    continue
  fi
  expect "$T hook rows" "$H_ROWS" -eq 4
  expect "$T plaintext input marker in hook rows" "$H_IN" -eq 0
  expect "$T plaintext account_no in hook rows" "$H_ACCT" -eq 0
  expect "$T rows holding enc:v1:" "$H_ENC" -eq 4
  expect "$T control rows" "$C_ROWS" -eq 2
  expect "$T control input marker in plaintext (positive control)" "$C_IN" -ge 1
  expect "$T control account_no in plaintext (positive control)" "$C_ACCT" -ge 1
  expect "$T plaintext OUTPUT marker in hook rows (output was not encrypted)" "$H_OUT" -ge 1
done

echo "════ 4. What the UI shows: the public API returns the stored values ════"
PUBAUTH="$PUB_A:$SEC_A"
# v4 events_only mode: GET /api/public/traces/<id> and /observations are 404 here; v2/observations serves the events table.
OBS=$(curl -fsS -m 30 -u "$PUBAUTH" "$HOST/api/public/v2/observations?traceId=${HOOK_IDS[0]}&fields=core,basic,io,metadata&limit=50")
echo "  GET /api/public/v2/observations?traceId=<hook trace>&fields=core,basic,io,metadata:"
echo "$OBS" | jq -c '.data[] | {name, input: (.input|tostring|.[0:50]), account_no: (.metadata.account_no|tostring|.[0:40]), output}'
expect "API observations whose input is ciphertext" "$(echo "$OBS" | jq '[.data[] | select(.input|tostring|startswith("enc:v1:"))] | length')" -eq 2
expect "API observations whose metadata.account_no is ciphertext" "$(echo "$OBS" | jq '[.data[] | select(.metadata.account_no|tostring|startswith("enc:v1:"))] | length')" -eq 2
expect "API observations holding the plaintext input marker" "$(echo "$OBS" | jq --arg m "$IN_MARK" '[.data[] | select(.input|tostring|contains($m))] | length')" -eq 0
CT_IN=$(echo "$OBS" | jq -r '.data[0].input')   # ciphertext, kept for the judge section

echo "════ 5. Reader: decrypt with the project's key (14-decrypt-fields.py) ════"
set +e; READ_OUT=$("$PY" 14-decrypt-fields.py "$PID_A" "$TS" "${HOOK_IDS[@]}"); READ_RC=$?; set -e
echo "$READ_OUT" | sed 's/^/  /'
FAILS=$((FAILS + $(echo "$READ_OUT" | grep -c '^FAIL' || true)))
expect "reader exit status" "$READ_RC" -eq 0
expect "reader PASS lines (2 traces x 2 observations x 6 checks)" "$(echo "$READ_OUT" | grep -c '^PASS')" -eq 24

echo "════ 6. UI search: tRPC events.all with searchType input/output (the v4 table's search) ════"
# Log in as the seeded admin (NextAuth credentials), add that user to the new org, then call the same tRPC
# procedure the UI calls. Credentials are read from _base/.env and never printed.
JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT
CSRF=$(curl -fsS -m 20 -c "$JAR" -b "$JAR" "$HOST/api/auth/csrf" | jq -r .csrfToken)
curl -fsS -m 20 -c "$JAR" -b "$JAR" -o /dev/null -X POST "$HOST/api/auth/callback/credentials" \
  --data-urlencode "csrfToken=$CSRF" --data-urlencode "email=$LANGFUSE_INIT_USER_EMAIL" \
  --data-urlencode "password=$LANGFUSE_INIT_USER_PASSWORD" --data-urlencode "json=true"
UID_ADMIN=$(curl -fsS -m 20 -b "$JAR" "$HOST/api/auth/session" | jq -r '.user.id // empty')
[[ -n "$UID_ADMIN" ]] || { echo "✗ UI login failed"; exit 1; }
orgcurl -X PUT "$HOST/api/public/organizations/memberships" -H "Content-Type: application/json" \
  -d "{\"userId\":\"$UID_ADMIN\",\"role\":\"OWNER\"}" >/dev/null
# search TYPE QUERY -> traceId of every matching observation, one per line
search() {
  local in
  in=$(jq -rn --arg p "$PID_A" --arg q "$2" --arg t "$1" \
    '{json:{projectId:$p,filter:[],orderBy:{column:"startTime",order:"DESC"},page:0,limit:50,searchQuery:$q,searchType:[$t]}}|tojson|@uri')
  curl -fsS -m 30 -b "$JAR" "$HOST/api/trpc/events.all?input=$in" | jq -r '.result.data.json.observations[].traceId'
}
count_in() { local n=0 t; for t in "${@:2}"; do n=$((n + $(grep -c "^$t$" <<<"$1" || true))); done; echo "$n"; }
R=$(search input "$IN_MARK");  expect "search input '$IN_MARK': hook-trace hits (ciphertext)" "$(count_in "$R" "${HOOK_IDS[@]}")" -eq 0
                               expect "search input '$IN_MARK': control hits (positive control)" "$(count_in "$R" "$CTRL_ID")" -ge 1
R=$(search output "$OUT_MARK"); expect "search output '$OUT_MARK': hook-trace hits (plaintext output)" "$(count_in "$R" "${HOOK_IDS[@]}")" -ge 2
                               expect "search output '$OUT_MARK': control hits" "$(count_in "$R" "$CTRL_ID")" -ge 1
R=$(search content "$IN_MARK"); expect "search content '$IN_MARK': hook-trace hits" "$(count_in "$R" "${HOOK_IDS[@]}")" -eq 0
                               expect "search content '$IN_MARK': control hits (positive control)" "$(count_in "$R" "$CTRL_ID")" -ge 1

echo "════ 7. LLM-as-a-judge: what {{input}} resolves to (no model is called) ════"
# The worker resolves a trace variable by reading the stored trace row and taking the mapped column
# (worker/dist/features/evaluation/evalService.js, extractVariablesFromTracingData: getTraceById -> parseDatabaseRowValue).
# Read from the image, not run: no evaluator and no model call is made here.
# So {{input}} is the stored value, which is the ciphertext; the judge model would be prompted with it.
# In events_only write mode (this stack) getTraceById reads the events table, i.e. the same stored values:
lf_compose -- exec -T langfuse-worker sh -c 'f=$(find /app/worker/node_modules/.pnpm -path "*server/repositories/events.js" | head -1); sed -n 641,646p "$f"' | sed 's/^/  events.js:  /'
lf_compose -- exec -T langfuse-worker sh -c "grep -n 'parseDatabaseRowValue(trace, mapping)' /app/worker/dist/features/evaluation/evalService.js" | sed 's/^/  evalService.js:/'
STORED=$(ch -q "SELECT input FROM events_full WHERE project_id='$PID_A' AND trace_id='${HOOK_IDS[0]}' AND parent_span_id='' LIMIT 1")
echo "  stored root input (what {{input}} gets): ${STORED:0:70}..."
expect "evaluator {{input}} is ciphertext" "$([[ "$STORED" == enc:v1:* && "$STORED" != *"$IN_MARK"* ]] && echo yes || echo no)" = yes

echo
if [[ "$FAILS" -eq 0 ]]; then echo "✅ All checks PASS (run $TS)."; else echo "✗ $FAILS check(s) FAILED (run $TS)."; exit 1; fi
