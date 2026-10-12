#!/usr/bin/env bash
# 14-judge-encrypted.sh — a real managed LLM-as-a-judge reading an encrypted `{{input}}` (lab 14 add-on).
#
#   setup   new org + one project + project key + a fresh AES-256 key in _base/.env.field-keys (as 14-field-encryption.sh)
#   judge   LLM connection (anthropic), evaluator (input only, NUMERIC 0..1), rule on root observations
#           named `transfer-status` — all with the project key, claude-haiku-4-5 only
#   send    14-field-encryption.py: 2 traces with the hook (input encrypted) + 1 control trace without it
#   check   ClickHouse: one EVAL score per root observation (control -> 1, encrypted -> 0), and the prompt the judge
#           actually sent (its own trace, environment langfuse-llm-as-a-judge) holds enc:v1: for the hook traces
#           and the plaintext for the control
#   clean   the rule is disabled on exit (also on failure) so later traces in the project cost nothing
#
# COSTS MONEY: one claude-haiku-4-5 call per matching root observation = 3 calls per run. Run only on purpose.
# Exits non-zero unless every check printed PASS or if no EVAL score appears within 3 minutes.
# Requires: EE overlay up (EE=1 _base/bin/up.sh v4), `jq`, `curl`, ANTHROPIC_API_KEY in _base/.env,
# .venv-v4 with _base/v4/requirements.txt.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "✗ please install jq"; exit 1; }
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || { echo "✗ set ANTHROPIC_API_KEY in _base/.env"; exit 1; }
PY="$BASE_DIR/../.venv-v4/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
ADMIN="Authorization: Bearer ${ADMIN_API_KEY:?set ADMIN_API_KEY in _base/.env}"
CH_USER="${CLICKHOUSE_USER:-clickhouse}"
CH_PASSWORD="${CLICKHOUSE_PASSWORD:-clickhouse}"
KEYS_FILE="$BASE_DIR/.env.field-keys"
MODEL="claude-haiku-4-5"
TS=$(date +%s)
FAILS=0
ch() { lf_compose -- exec -T clickhouse clickhouse-client -u "$CH_USER" --password "$CH_PASSWORD" "$@"; }
pass() { echo "PASS  $1: $2"; }
fail() { echo "FAIL  $1: $2"; FAILS=$((FAILS + 1)); }
expect() { if [ "$2" "$3" "$4" ]; then pass "$1" "$2"; else fail "$1" "$2 (wanted $3 $4)"; fi; }

RULE_ID=""; PAUTH=""
disable_rule() {   # PATCH {enabled:false}, then read it back
  [[ -n "$RULE_ID" && -n "$PAUTH" ]] || return 0
  curl -sS -m 30 -u "$PAUTH" -X PATCH "$HOST/api/public/v2/evaluation-rules/$RULE_ID" -H "Content-Type: application/json" \
    -d '{"enabled":false}' >/dev/null || true
  local en; en=$(curl -sS -m 30 -u "$PAUTH" "$HOST/api/public/v2/evaluation-rules/$RULE_ID" | jq -r '.enabled | tostring')
  echo "  cleanup: rule $RULE_ID enabled=$en (leaves the LLM connection in place)"
  [[ "$en" == false ]] || { echo "FAIL  rule still enabled after cleanup - disable it in the UI"; return 1; }
}
trap 'disable_rule' EXIT

echo "════ 1. Setup: org, project, API key, AES-256 key ════"
ORG_ID=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations" -H "$ADMIN" -H "Content-Type: application/json" \
  -d "{\"name\":\"judge-enc-$TS\"}" | jq -r .id)
ORG_KEY=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations/$ORG_ID/apiKeys" -H "$ADMIN" \
  -H "Content-Type: application/json" -d '{"note":"lab 14 judge"}')
ORG_AUTH="$(echo "$ORG_KEY" | jq -r .publicKey):$(echo "$ORG_KEY" | jq -r .secretKey)"
orgcurl() { curl -fsS -m 30 -u "$ORG_AUTH" "$@"; }
umask 077; touch "$KEYS_FILE"; chmod 600 "$KEYS_FILE"
git -C "$BASE_DIR" check-ignore -q "$KEYS_FILE" || { echo "✗ $KEYS_FILE is not gitignored"; exit 1; }
PID=$(orgcurl -X POST "$HOST/api/public/projects" -H "Content-Type: application/json" \
  -d "{\"name\":\"judge-enc-$TS\",\"retention\":0}" | jq -r .id)
PK=$(orgcurl -X POST "$HOST/api/public/projects/$PID/apiKeys" -H "Content-Type: application/json" -d '{"note":"lab 14 judge"}')
PUB=$(echo "$PK" | jq -r .publicKey); SEC=$(echo "$PK" | jq -r .secretKey); PAUTH="$PUB:$SEC"
printf 'FIELD_KEY_%s=%s\n' "$PID" "$("$PY" -c 'import base64,secrets;print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())')" >> "$KEYS_FILE"
echo "  org $ORG_ID  project $PID  (AES key written to _base/.env.field-keys, never printed)"
pcurl() { curl -sS -m 60 -u "$PAUTH" -H "Content-Type: application/json" "$@"; }
export FE_PUBLIC_KEY="$PUB" FE_SECRET_KEY="$SEC" LANGFUSE_HOST="$HOST"

echo "════ 2. Judge: LLM connection, evaluator (input only), rule on root observations ════"
# The Anthropic key goes from the environment into jq and on to curl's stdin: not on any command line, never printed.
CONN=$(jq -n 'env.ANTHROPIC_API_KEY as $k | {provider:"anthropic", adapter:"anthropic", secretKey:$k, withDefaultModels:true}' \
  | pcurl -X PUT "$HOST/api/public/llm-connections" -d @-)
echo "  LLM connection: $(echo "$CONN" | jq -c '{provider, adapter, withDefaultModels}')"
[[ "$(echo "$CONN" | jq -r .provider)" == anthropic ]] || { echo "✗ LLM connection not created"; exit 1; }
# Only {{input}} is mapped: the judge cannot infer the question from the (plaintext) output.
EV=$(jq -n --arg m "$MODEL" --arg n "transfer-question-$TS" '{
    name:$n, type:"llm_as_judge",
    prompt:"You classify a customer'"'"'s banking question.\nQuestion: {{input}}\nScore 1 if the text is a readable natural-language question about the status of a money transfer (a reference code inside it is fine). Score 0 if it is encrypted, encoded or otherwise unreadable, or about something else.",
    modelConfig:{provider:"anthropic", model:$m},
    variableMapping:[{variable:"input",source:"input"}],
    outputDefinition:{dataType:"NUMERIC", minValue:0, maxValue:1,
      scoreReasoningInstructions:"One sentence: say what the question text is or why it is not readable.",
      scoreValueInstructions:"1 = readable question about a money transfer status, 0 = unreadable (ciphertext, encoding) or anything else."}}' \
  | pcurl -X POST "$HOST/api/public/v2/evaluators" -d @-)
EVALUATOR_ID=$(echo "$EV" | jq -r '.id // empty')
[[ -n "$EVALUATOR_ID" ]] || { echo "✗ evaluator not created: $(echo "$EV" | head -c 300)"; exit 1; }
RULE=$(jq -n --arg e "$EVALUATOR_ID" --arg n "judge transfer-status roots $TS" '{
    name:$n, enabled:true, sampling:1,
    filter:[{type:"boolean", column:"isRootObservation", operator:"=", value:true},
            {type:"stringOptions", column:"name", operator:"any of", value:["transfer-status"]}],
    evaluatorAssignments:[{evaluatorId:$e}]}' \
  | pcurl -X POST "$HOST/api/public/v2/evaluation-rules" -d @-)
RULE_ID=$(echo "$RULE" | jq -r '.id // empty')
[[ -n "$RULE_ID" ]] || { echo "✗ rule not created: $(echo "$RULE" | head -c 300)"; exit 1; }
echo "  evaluator $EVALUATOR_ID  rule $RULE_ID  enabled=$(echo "$RULE" | jq -r .enabled)  model $MODEL"

echo "════ 3. Send: 2 traces with the hook (encrypted input), 1 control trace without ════"
HOOK_OUT=$("$PY" 14-field-encryption.py hook "$PID" "$TS" 2)
HOOK_IDS=($(echo "$HOOK_OUT" | awk '/^TRACE_ID/ {print $2}'))
CTRL_ID=$("$PY" 14-field-encryption.py control "$PID" "$TS" | awk '/^TRACE_ID/ {print $2}')
echo "  hook traces: ${HOOK_IDS[*]}"; echo "  control trace: $CTRL_ID"
IN_MARK="ENCMARK-IN-$TS"
ALL_LIST="'${HOOK_IDS[0]}','${HOOK_IDS[1]}','$CTRL_ID'"

echo "════ 4. Wait (max 3 min) for EVAL scores on the 3 root observations ════"
N=0
for _ in $(seq 1 36); do
  N=$(ch -q "SELECT uniqExact(trace_id) FROM scores FINAL WHERE project_id='$PID' AND source='EVAL' AND trace_id IN ($ALL_LIST)")
  [[ "$N" -ge 3 ]] && break; sleep 5
done
echo "  traces with an EVAL score: $N of 3"
[[ "$N" -ge 1 ]] || { fail "any EVAL score within 3 min" "0 (check the worker log and the judge traces in the UI)"; echo "✗ $FAILS check(s) FAILED (run $TS)."; exit 1; }

SCORES=$(ch -q "SELECT trace_id, observation_id, name, value, comment, source FROM scores FINAL
       WHERE project_id='$PID' AND trace_id IN ($ALL_LIST) ORDER BY trace_id FORMAT JSONEachRow")
score_of() { jq -s -r --arg t "$1" --arg f "$2" '[.[] | select(.trace_id==$t and .source=="EVAL")][0] | .[$f] // empty' <<<"$SCORES"; }
for T in "${HOOK_IDS[0]}" "${HOOK_IDS[1]}" "$CTRL_ID"; do
  KIND=encrypted; [[ "$T" == "$CTRL_ID" ]] && KIND=control
  echo "  $KIND $T  value=$(score_of "$T" value)  source=$(score_of "$T" source)"
  echo "      reasoning: $(score_of "$T" comment)"
done
expect "EVAL scores on the 3 root observations" "$N" -eq 3
for T in "${HOOK_IDS[0]}" "${HOOK_IDS[1]}"; do
  expect "encrypted trace ${T:0:8} judged unreadable (value 0)" "$(score_of "$T" value)" = 0
done
expect "control trace judged a transfer question (value 1, positive control)" "$(score_of "$CTRL_ID" value)" = 1
CTRL_WHY=$(score_of "$CTRL_ID" comment)
expect "control reasoning mentions a transfer" "$(grep -ciE 'transfer' <<<"$CTRL_WHY" || true)" -ge 1

echo "════ 5. The prompt the judge actually sent (its own trace, environment langfuse-llm-as-a-judge) ════"
for _ in $(seq 1 15); do
  J=$(ch -q "SELECT uniqExact(trace_id) FROM events_full WHERE project_id='$PID' AND environment='langfuse-llm-as-a-judge'")
  [[ "$J" -ge "$N" ]] && break; sleep 4
done
echo "  judge traces in this project: $J; observations by type:"
ch -q "SELECT type, count() FROM events_full WHERE project_id='$PID' AND environment='langfuse-llm-as-a-judge' GROUP BY type ORDER BY type FORMAT TSV" | sed 's/^/    /'
# One value per judge input: the 'Question:' line only (first 70 chars), not the whole payload.
SNIP="substring(input, position(input, 'Question: '), 90)"
judge_hits() {   # judge observations whose input contains the given literal
  ch -q "SELECT count() FROM events_full WHERE project_id='$PID' AND environment='langfuse-llm-as-a-judge' AND position(input, '$1') > 0"
}
for T in "${HOOK_IDS[@]}"; do
  CT=$(ch -q "SELECT input FROM events_full WHERE project_id='$PID' AND trace_id='$T' AND parent_span_id='' LIMIT 1")
  expect "stored input of ${T:0:8} is ciphertext" "$([[ "$CT" == enc:v1:* ]] && echo yes || echo no)" = yes
  expect "judge prompt for ${T:0:8} holds that exact ciphertext" "$(judge_hits "$CT")" -ge 1
  echo "      judge sent: $(ch -q "SELECT $SNIP FROM events_full WHERE project_id='$PID' AND environment='langfuse-llm-as-a-judge' AND position(input, '$CT') > 0 LIMIT 1")"
done
expect "judge prompt for the control holds the plaintext marker (positive control)" "$(judge_hits "$IN_MARK-CTRL")" -ge 1
echo "      judge sent: $(ch -q "SELECT $SNIP FROM events_full WHERE project_id='$PID' AND environment='langfuse-llm-as-a-judge' AND position(input, '$IN_MARK-CTRL') > 0 LIMIT 1")"
expect "judge prompts holding a plaintext marker without -CTRL (i.e. from an encrypted trace)" \
  "$(ch -q "SELECT countIf(position(input, '$IN_MARK') > 0 AND position(input, '$IN_MARK-CTRL') = 0) FROM events_full WHERE project_id='$PID' AND environment='langfuse-llm-as-a-judge'")" -eq 0
echo "  judge calls made by this run (generation observations): $(ch -q "SELECT countIf(type='GENERATION') FROM events_full WHERE project_id='$PID' AND environment='langfuse-llm-as-a-judge'")"

echo "════ 6. Cleanup ════"
disable_rule || FAILS=$((FAILS + 1))
RULE_ID=""

echo
if [[ "$FAILS" -eq 0 ]]; then echo "✅ All checks PASS (run $TS)."; else echo "✗ $FAILS check(s) FAILED (run $TS)."; exit 1; fi
