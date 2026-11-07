#!/usr/bin/env bash
# 18-ee-protected-labels.sh — who may move `production` once it is a protected prompt label?
#
# Step 09 moves `production` between versions and describes protection. This step protects the
# label and measures, with real users and a real project API key, who can still move it:
#
#   - before protection a MEMBER can move `production` (the control: the denial below is protection);
#   - after protection a MEMBER cannot move it, remove it, create a version carrying it, delete the
#     labelled version or delete the prompt; a MEMBER can still create an unlabelled version;
#   - `latest` cannot be protected; a MEMBER cannot protect a label; an ADMIN can move it;
#   - a project API key (public API) CAN still move it: Langfuse v4.56.0
#     web/src/features/prompts/server/utils/authorizeProtectedLabelMutation.ts says
#     "Ordinary project API keys may still promote protected labels (CI)";
#   - the audit log records each change with its actor type (USER or API_KEY);
#   - with --license-off, the stack is restarted without the license and the same calls are repeated:
#     is protection still enforced, can it still be changed, is the audit record still written?
#
# Users: an org ADMIN ("release admin") and an org MEMBER, created through the sign-up endpoint and
# logged in over NextAuth credentials with a cookie jar (as in step 13). Passwords are generated at run
# time, kept in a mode-700 temp dir and never printed. --keep-users writes them to $KEEP_DIR (mode 600)
# instead, so the same users can sign in to the UI for screen captures; delete that dir afterwards.
#
# Requires: EE active (run 05 first), jq, openssl, ADMIN_API_KEY in _base/.env.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

LICENSE_OFF=0; KEEP_USERS=0
for a in "$@"; do
  case "$a" in
    --license-off) LICENSE_OFF=1 ;;
    --keep-users)  KEEP_USERS=1 ;;
    *) echo "usage: $0 [--license-off] [--keep-users]"; exit 2 ;;
  esac
done

for c in jq openssl curl; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
ADMIN="Authorization: Bearer ${ADMIN_API_KEY:?set ADMIN_API_KEY in _base/.env}"
TS=$(date +%Y%m%d%H%M%S)
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
KEEP_DIR="${KEEP_DIR:-$HOME/.cache/langfuse-hols/18-users}"

ROWS="$WORK/rows.tsv"; : > "$ROWS"; FAILS=0
# row <actor> <action> <expected> <observed> <ok:0|1>
row() {
  local res=PASS; [ "$5" = 1 ] || { res=FAIL; FAILS=$((FAILS+1)); }
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$res" >> "$ROWS"
  echo "  $res  $1 | $2 | expected: $3 | observed: $4"
}
g() { local n="$1_$2"; echo "${!n}"; }   # g VAR key → value (bash 3.2 has no assoc arrays)
PSQL=(lf_compose -- exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -P pager=off)

wait_web() {
  for _ in $(seq 1 80); do curl -fsS -m 5 "$HOST/api/public/health" >/dev/null 2>&1 && return 0; sleep 3; done
  echo "✗ langfuse-web did not become healthy"; exit 1
}

echo "════ 1. Organization, project, project API key (admin + org API) ════"
ORG_ID=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations" -H "$ADMIN" -H "Content-Type: application/json" \
  -d "{\"name\":\"prompt-governance-$TS\"}" | jq -r .id)
ORG_KEY=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations/$ORG_ID/apiKeys" -H "$ADMIN" \
  -H "Content-Type: application/json" -d '{"note":"protected labels test"}')
ORG_AUTH="$(echo "$ORG_KEY" | jq -r .publicKey):$(echo "$ORG_KEY" | jq -r .secretKey)"
orgcurl() { curl -fsS -m 30 -u "$ORG_AUTH" "$@"; }
PID=$(orgcurl -X POST "$HOST/api/public/projects" -H "Content-Type: application/json" \
  -d "{\"name\":\"prompts-$TS\",\"retention\":0}" | jq -r .id)
K=$(orgcurl -X POST "$HOST/api/public/projects/$PID/apiKeys" -H "Content-Type: application/json" -d '{"note":"ci deploy key"}')
PAUTH="$(echo "$K" | jq -r .publicKey):$(echo "$K" | jq -r .secretKey)"
PKEY_ID=$(echo "$K" | jq -r .id)
echo "  org id = $ORG_ID   project id = $PID   ci deploy credential (row) = $PKEY_ID"

echo "════ 2. Two local users: an org ADMIN (release admin) and an org MEMBER ════"
USERS=(reladmin member)
if [ $KEEP_USERS = 1 ]; then mkdir -p "$KEEP_DIR"; chmod 700 "$KEEP_DIR"; fi
for u in "${USERS[@]}"; do
  printf -v "EMAIL_$u" "%s" "$u-$TS@governance.test"
  printf 'Aa1!%s' "$(openssl rand -hex 12)" > "$WORK/pw-$u"
  name="Release Admin"; [ "$u" = member ] && name="Prompt Member"
  jq -n --arg e "$(g EMAIL $u)" --arg n "$name" --rawfile p "$WORK/pw-$u" \
    '{name:$n,email:$e,password:$p}' | curl -fsS -m 30 -X POST "$HOST/api/auth/signup" \
    -H "Content-Type: application/json" -d @- | jq -r .message
  if [ $KEEP_USERS = 1 ]; then
    cp "$WORK/pw-$u" "$KEEP_DIR/pw-$u"; echo "$(g EMAIL $u)" > "$KEEP_DIR/email-$u"; chmod 600 "$KEEP_DIR"/*
  fi
done

login() {
  local u=$1 jar="$WORK/jar-$1"
  : > "$jar"
  local csrf; csrf=$(curl -fsS -m 30 -c "$jar" -b "$jar" "$HOST/api/auth/csrf" | jq -r .csrfToken)
  curl -sS -m 30 -c "$jar" -b "$jar" -o /dev/null -X POST "$HOST/api/auth/callback/credentials" \
    --data-urlencode "csrfToken=$csrf" --data-urlencode "email=$(g EMAIL $u)" \
    --data-urlencode "password@$WORK/pw-$u" --data-urlencode "callbackUrl=$HOST/" --data-urlencode "json=true"
  curl -fsS -m 30 -b "$jar" -c "$jar" "$HOST/api/auth/session"
}
for u in "${USERS[@]}"; do
  printf -v "UID__$u" "%s" "$(login "$u" | jq -r '.user.id // empty')"
  [ -n "$(g UID_ $u)" ] || { echo "✗ login failed for $u"; exit 1; }
done
orgcurl -X PUT "$HOST/api/public/organizations/memberships" -H "Content-Type: application/json" \
  -d "{\"userId\":\"$(g UID_ reladmin)\",\"role\":\"ADMIN\"}" >/dev/null
orgcurl -X PUT "$HOST/api/public/organizations/memberships" -H "Content-Type: application/json" \
  -d "{\"userId\":\"$(g UID_ member)\",\"role\":\"MEMBER\"}" >/dev/null
for u in "${USERS[@]}"; do login "$u" > "$WORK/session-$u.json"; done
for u in "${USERS[@]}"; do
  r=$(jq -r --arg org "$ORG_ID" '[.user.organizations[]?|select(.id==$org)|.role]|first // "none"' "$WORK/session-$u.json")
  exp=ADMIN; [ "$u" = member ] && exp=MEMBER
  [ "$r" = "$exp" ] && ok=1 || ok=0; row "$u" "org role in session" "$exp" "$r" $ok
done

trpc_get() {
  curl -sS -m 60 -b "$WORK/jar-$1" -w '\n%{http_code}' -G "$HOST/api/trpc/$2" \
    --data-urlencode "input={\"json\":$3}" | awk 'NR==1{b=$0;next}{print $0" "b}'
}
trpc_post() {
  curl -sS -m 60 -b "$WORK/jar-$1" -w '\n%{http_code}' -X POST "$HOST/api/trpc/$2" \
    -H "Content-Type: application/json" -d "{\"json\":$3}" | awk 'NR==1{b=$0;next}{print $0" "b}'
}
describe() {  # "<code> <body>" → "HTTP 200" | "HTTP 403 FORBIDDEN"
  local code=${1%% *} body=${1#* } e
  e=$(echo "$body" | jq -r '.error.json.data.code // empty' 2>/dev/null || true)
  echo "HTTP $code${e:+ $e}"
}
is_ok()     { [ "${1%% *}" = 200 ] || [ "${1%% *}" = 201 ]; }   # public API create answers 201
is_denied() { describe "$1" | grep -Eq '^HTTP 403 FORBIDDEN$'; }
# api <method> <path> [json] → "<code> <body>" with the project API key (Basic auth)
api() {
  curl -sS -m 30 -u "$PAUTH" -w '\n%{http_code}' -X "$1" "$HOST$2" -H "Content-Type: application/json" \
    ${3:+-d "$3"} | awk 'NR==1{b=$0;next}{print $0" "b}'
}

NAME="loan-advice-system"
prod_version() {  # version currently carrying `production`, as an app resolves it
  curl -sS -m 30 -u "$PAUTH" "$HOST/api/public/v2/prompts/$NAME?label=production" | jq -r '.version // "none"'
}
vid() {  # prompt row id of version $1
  "${PSQL[@]}" -tAc "SELECT id FROM prompts WHERE project_id='$PID' AND name='$NAME' AND version=$1;" | tr -d '[:space:]'
}
nversions() { "${PSQL[@]}" -tAc "SELECT count(*) FROM prompts WHERE project_id='$PID' AND name='$NAME';" | tr -d '[:space:]'; }
labels_table() {
  "${PSQL[@]}" -c "SELECT version, labels, created_by FROM prompts WHERE project_id='$PID' AND name='$NAME' ORDER BY version;"
}
create_json() {  # create_json <labels-json> <text>
  jq -cn --arg p "$PID" --arg n "$NAME" --argjson l "$1" --arg t "$2" \
    '{projectId:$p,name:$n,type:"text",prompt:$t,labels:$l,config:{},commitMessage:"lab 18"}'
}

echo "════ 3. Before protection: v1 from the API key, v2 from the MEMBER, MEMBER moves production (control) ════"
r=$(api POST /api/public/v2/prompts "$(jq -cn --arg n "$NAME" '{type:"text",name:$n,prompt:"v1: answer from the product sheet only.",labels:["production"],config:{}}')")
is_ok "$r" && ok=1 || ok=0; row apikey "create v1 with production (public API)" "HTTP 201" "$(describe "$r")" $ok
r=$(trpc_post member prompts.create "$(create_json '[]' 'v2: answer from the product sheet; cite the clause.')")
is_ok "$r" && ok=1 || ok=0; row member "create v2, no label (tRPC prompts.create)" "HTTP 200" "$(describe "$r")" $ok
r=$(trpc_post member prompts.setLabels "{\"projectId\":\"$PID\",\"promptId\":\"$(vid 2)\",\"labels\":[\"production\"]}")
pv=$(prod_version)
is_ok "$r" && [ "$pv" = 2 ] && ok=1 || ok=0
row member "move production v1→v2, label not protected (tRPC setLabels)" "HTTP 200, production=v2" "$(describe "$r"), production=v$pv" $ok

echo "════ 4. Protect production ════"
r=$(trpc_post member prompts.addProtectedLabel "{\"projectId\":\"$PID\",\"label\":\"production\"}")
is_denied "$r" && ok=1 || ok=0; row member "protect production (addProtectedLabel)" "HTTP 403 FORBIDDEN" "$(describe "$r")" $ok
r=$(trpc_post reladmin prompts.addProtectedLabel "{\"projectId\":\"$PID\",\"label\":\"latest\"}")
describe "$r" | grep -q '^HTTP 400 BAD_REQUEST$' && ok=1 || ok=0
row reladmin "protect latest (addProtectedLabel)" "HTTP 400 BAD_REQUEST" "$(describe "$r")" $ok
r=$(trpc_post reladmin prompts.addProtectedLabel "{\"projectId\":\"$PID\",\"label\":\"production\"}")
is_ok "$r" && ok=1 || ok=0; row reladmin "protect production (addProtectedLabel)" "HTTP 200" "$(describe "$r")" $ok
pl=$("${PSQL[@]}" -tAc "SELECT string_agg(label, ',' ORDER BY label) FROM prompt_protected_labels WHERE project_id='$PID';" | tr -d '[:space:]')
[ "$pl" = production ] && ok=1 || ok=0; row postgres "prompt_protected_labels for the project" "production" "${pl:-none}" $ok

member_checks() {  # $1 = suffix for the action names; reads PROD_NOW (holds production) and OTHER (does not)
  local s="$1" n0 n1 r pv
  r=$(trpc_post member prompts.setLabels "{\"projectId\":\"$PID\",\"promptId\":\"$(vid "$OTHER")\",\"labels\":[\"production\"]}")
  pv=$(prod_version)
  is_denied "$r" && [ "$pv" = "$PROD_NOW" ] && ok=1 || ok=0
  row member "move production v$PROD_NOW→v$OTHER (setLabels)$s" "HTTP 403 FORBIDDEN, production=v$PROD_NOW" "$(describe "$r"), production=v$pv" $ok
  r=$(trpc_post member prompts.setLabels "{\"projectId\":\"$PID\",\"promptId\":\"$(vid "$PROD_NOW")\",\"labels\":[]}")
  pv=$(prod_version)
  is_denied "$r" && [ "$pv" = "$PROD_NOW" ] && ok=1 || ok=0
  row member "remove production from v$PROD_NOW (setLabels)$s" "HTTP 403 FORBIDDEN, production=v$PROD_NOW" "$(describe "$r"), production=v$pv" $ok
  n0=$(nversions)
  r=$(trpc_post member prompts.create "$(create_json '["production"]' 'member tries to ship this')")
  n1=$(nversions); pv=$(prod_version)
  is_denied "$r" && [ "$n1" = "$n0" ] && [ "$pv" = "$PROD_NOW" ] && ok=1 || ok=0
  row member "create a version carrying production (prompts.create)$s" "HTTP 403 FORBIDDEN, no new version" "$(describe "$r"), versions $n0→$n1, production=v$pv" $ok
  r=$(trpc_post member prompts.create "$(create_json '[]' 'member draft, not deployed')")
  n1=$(nversions)
  is_ok "$r" && [ "$n1" = $((n0+1)) ] && ok=1 || ok=0
  row member "create an unlabelled version (prompts.create, control)$s" "HTTP 200, one new version" "$(describe "$r"), versions $n0→$n1" $ok
  r=$(trpc_post member prompts.deleteVersion "{\"projectId\":\"$PID\",\"promptVersionId\":\"$(vid "$PROD_NOW")\"}")
  is_denied "$r" && [ -n "$(vid "$PROD_NOW")" ] && ok=1 || ok=0
  row member "delete the production version (deleteVersion)$s" "HTTP 403 FORBIDDEN, version kept" "$(describe "$r")" $ok
  r=$(trpc_post member prompts.delete "{\"projectId\":\"$PID\",\"promptName\":\"$NAME\"}")
  n1=$(nversions)
  is_denied "$r" && [ "$n1" -ge 1 ] && ok=1 || ok=0
  row member "delete the prompt (prompts.delete)$s" "HTTP 403 FORBIDDEN, prompt kept" "$(describe "$r"), versions=$n1" $ok
}

echo "════ 5. MEMBER after protection ════"
PROD_NOW=2; OTHER=1
member_checks ""

echo "════ 6. ADMIN moves production back to v1 ════"
r=$(trpc_post reladmin prompts.setLabels "{\"projectId\":\"$PID\",\"promptId\":\"$(vid 1)\",\"labels\":[\"production\"]}")
pv=$(prod_version)
is_ok "$r" && [ "$pv" = 1 ] && ok=1 || ok=0
row reladmin "move production v2→v1 (setLabels)" "HTTP 200, production=v1" "$(describe "$r"), production=v$pv" $ok
PROD_NOW=1

echo "════ 7. The project API key (what a CI pipeline holds) ════"
r=$(api POST /api/public/v2/prompts "$(jq -cn --arg n "$NAME" '{type:"text",name:$n,prompt:"ci: shipped by the pipeline",labels:["production"],config:{}}')")
newv=$(echo "${r#* }" | jq -r '.version // empty' 2>/dev/null); pv=$(prod_version)
is_ok "$r" && [ -n "$newv" ] && [ "$pv" = "$newv" ] && ok=1 || ok=0
row apikey "create a version carrying production (POST /api/public/v2/prompts)" "HTTP 201, production moves (by design)" "$(describe "$r"), production=v$pv" $ok
r=$(api PATCH "/api/public/v2/prompts/$NAME/versions/1" '{"newLabels":["production"]}')
pv=$(prod_version)
is_ok "$r" && [ "$pv" = 1 ] && ok=1 || ok=0
row apikey "move production to v1 (PATCH …/versions/1)" "HTTP 200, production=v1 (by design)" "$(describe "$r"), production=v$pv" $ok
PROD_NOW=1
r=$(api DELETE "/api/public/v2/prompts/$NAME?version=1")
pv=$(prod_version)
code=${r%% *}
[ "$code" = 204 ] || [ "$code" = 200 ] && ok=1 || ok=0
[ $ok = 1 ] && PROD_NOW=none
row apikey "delete the production version (DELETE …?version=1)" "HTTP 2xx (by design)" "HTTP $code, production=v$pv" $ok

echo "════ 8. What Postgres holds now ════"
labels_table

echo "════ 9. Audit log (Postgres audit_logs) for this project ════"
"${PSQL[@]}" -c "SELECT to_char(created_at,'HH24:MI:SS.MS') AS at, type AS actor, resource_type, action,
  CASE WHEN user_id='$(g UID_ reladmin)' THEN 'reladmin' WHEN user_id='$(g UID_ member)' THEN 'member'
       WHEN api_key_id='$PKEY_ID' THEN 'project key' ELSE coalesce(user_id, api_key_id, '?') END AS who,
  coalesce(after::jsonb->>'version', after::jsonb->>'label', '') AS version_or_label,
  coalesce(after::jsonb->>'labels', '') AS labels_after
  FROM audit_logs WHERE project_id='$PID' ORDER BY created_at;"
na=$("${PSQL[@]}" -tAc "SELECT count(*) FROM audit_logs WHERE project_id='$PID' AND resource_type='promptProtectedLabel' AND action='create' AND type='USER' AND user_id='$(g UID_ reladmin)';" | tr -d '[:space:]')
[ "$na" = 1 ] && ok=1 || ok=0; row audit "protection recorded (promptProtectedLabel.create by reladmin)" "1" "$na" $ok
nk=$("${PSQL[@]}" -tAc "SELECT count(*) FROM audit_logs WHERE project_id='$PID' AND type='API_KEY' AND api_key_id='$PKEY_ID' AND resource_type='prompt';" | tr -d '[:space:]')
[ "$nk" -ge 3 ] 2>/dev/null && ok=1 || ok=0; row audit "API-key prompt changes recorded with the key id" ">= 3" "$nk" $ok
# After protection the MEMBER's only successful prompt change is the unlabelled create; every denied
# call must leave nothing (the control move before protection is the one setLabel record of theirs).
nd=$("${PSQL[@]}" -tAc "SELECT count(*) FROM audit_logs WHERE project_id='$PID' AND type='USER' AND user_id='$(g UID_ member)' AND resource_type='prompt' AND action<>'create' AND created_at > (SELECT min(created_at) FROM audit_logs WHERE project_id='$PID' AND resource_type='promptProtectedLabel');" | tr -d '[:space:]')
[ "$nd" = 0 ] && ok=1 || ok=0; row audit "denied MEMBER attempts after protection leave no record" "0" "$nd" $ok
nc=$("${PSQL[@]}" -tAc "SELECT count(*) FROM audit_logs WHERE project_id='$PID' AND type='USER' AND user_id='$(g UID_ member)' AND resource_type='prompt' AND action='setLabel';" | tr -d '[:space:]')
[ "$nc" = 1 ] && ok=1 || ok=0; row audit "MEMBER's move before protection recorded (control)" "1" "$nc" $ok

if [ $LICENSE_OFF = 1 ]; then
  echo "════ 10. License off: restart web + worker without the EE overlay ════"
  # The base compose file alone: no LANGFUSE_EE_LICENSE_KEY in either container.
  lf_compose -- up -d langfuse-web langfuse-worker >/dev/null 2>&1
  wait_web
  k=$( { lf_compose -- exec -T langfuse-web printenv LANGFUSE_EE_LICENSE_KEY 2>/dev/null || true; } | wc -c | tr -d ' ')
  [ "$k" -le 1 ] && ok=1 || ok=0; row stack "license key in langfuse-web after restart" "absent" "$([ "$k" -le 1 ] && echo absent || echo present)" $ok
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "$ADMIN" "$HOST/api/admin/organizations")
  [ "$code" != 200 ] && ok=1 || ok=0; row stack "admin API without the license (positive control that EE is off)" "not 200" "HTTP $code" $ok
  for u in "${USERS[@]}"; do login "$u" > /dev/null; done
  T_OFF=$("${PSQL[@]}" -tAc "SELECT now();" | sed 's/^ *//')
  # Put production back on a version so the checks have a pointer to defend.
  PROD_NOW=2; OTHER=3
  r=$(trpc_post reladmin prompts.setLabels "{\"projectId\":\"$PID\",\"promptId\":\"$(vid 2)\",\"labels\":[\"production\"]}")
  pv=$(prod_version)
  is_ok "$r" && [ "$pv" = 2 ] && ok=1 || ok=0
  row reladmin "move production to v2 (setLabels) [license off]" "HTTP 200, production=v2" "$(describe "$r"), production=v$pv" $ok
  member_checks " [license off]"
  r=$(trpc_post reladmin prompts.addProtectedLabel "{\"projectId\":\"$PID\",\"label\":\"staging\"}")
  is_denied "$r" && ok=1 || ok=0; row reladmin "protect staging (addProtectedLabel) [license off]" "HTTP 403 FORBIDDEN (entitlement)" "$(describe "$r")" $ok
  r=$(trpc_post reladmin prompts.removeProtectedLabel "{\"projectId\":\"$PID\",\"label\":\"production\"}")
  pl=$("${PSQL[@]}" -tAc "SELECT count(*) FROM prompt_protected_labels WHERE project_id='$PID' AND label='production';" | tr -d '[:space:]')
  is_denied "$r" && [ "$pl" = 1 ] && ok=1 || ok=0
  row reladmin "unprotect production (removeProtectedLabel) [license off]" "HTTP 403 FORBIDDEN, still protected" "$(describe "$r"), rows=$pl" $ok
  na=$("${PSQL[@]}" -tAc "SELECT count(*) FROM audit_logs WHERE project_id='$PID' AND user_id='$(g UID_ reladmin)' AND resource_type='prompt' AND created_at > '$T_OFF' AND action='setLabel';" | tr -d '[:space:]')
  [ "$na" = 0 ] && ok=1 || ok=0; row audit "reladmin's label move [license off] recorded" "0 (audit logs are EE)" "$na" $ok

  echo "════ 11. License back on ════"
  lf_compose ee -- up -d langfuse-web langfuse-worker >/dev/null 2>&1
  wait_web
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "$ADMIN" "$HOST/api/admin/organizations")
  [ "$code" = 200 ] && ok=1 || ok=0; row stack "admin API with the license again" "HTTP 200" "HTTP $code" $ok
fi

echo "════ Result ════"
column -t -s $'\t' "$ROWS" 2>/dev/null || cat "$ROWS"
echo "  PASS $(grep -c $'\tPASS$' "$ROWS")  FAIL $FAILS"
[ $KEEP_USERS = 1 ] && echo "  users kept for the UI: $KEEP_DIR (delete it when done)"
[ $FAILS = 0 ]
