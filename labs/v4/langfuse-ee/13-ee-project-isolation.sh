#!/usr/bin/env bash
# 13-ee-project-isolation.sh — does project-level RBAC isolate projects from each other?
#
# Claim under test: a user with organization role NONE and VIEWER on project A only
#   - cannot see project B in the session's project list, the tRPC API behind the UI, or the UI pages;
#   - cannot write on A (VIEWER is read-only, so the isolation is not just "no membership");
# while an organization ADMIN sees every project. Project API keys are scoped to their own project.
#
# Everything runs as real users: two local email/password users are created through the
# sign-up endpoint (SCIM does not take a password), given memberships through the org-scoped
# public API, and then log in over NextAuth credentials with a cookie jar.
#
# Requires: EE active (run 05 first), `jq`, `openssl`, ADMIN_API_KEY in _base/.env.
# Passwords are generated at run time, kept in a mode-700 temp dir and never printed.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

for c in jq openssl curl; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
ADMIN="Authorization: Bearer ${ADMIN_API_KEY:?set ADMIN_API_KEY in _base/.env}"
TS=$(date +%Y%m%d%H%M%S)
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT

ROWS="$WORK/rows.tsv"; : > "$ROWS"; FAILS=0
# row <actor> <surface> <project> <expected> <observed> <ok:0|1>
row() {
  local res=PASS; [ "$6" = 1 ] || { res=FAIL; FAILS=$((FAILS+1)); }
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$res" >> "$ROWS"
  echo "  $res  $1 | $2 | $3 | expected: $4 | observed: $5"
}

echo "════ 1. Organization, two projects, one API key and one trace per project ════"
# Ingestion goes through OTLP/JSON: with LANGFUSE_MIGRATION_V4_WRITE_MODE=events_only the legacy
# /api/public/ingestion rejects trace-create and GET /api/public/traces is switched off (checked 4.56.0).
# The OTLP traceId becomes the Langfuse trace id; one root span per trace.
ORG_ID=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations" -H "$ADMIN" -H "Content-Type: application/json" \
  -d "{\"name\":\"isolation-$TS\"}" | jq -r .id)
ORG_KEY=$(curl -fsS -m 30 -X POST "$HOST/api/admin/organizations/$ORG_ID/apiKeys" -H "$ADMIN" \
  -H "Content-Type: application/json" -d '{"note":"isolation test"}')
ORG_AUTH="$(echo "$ORG_KEY" | jq -r .publicKey):$(echo "$ORG_KEY" | jq -r .secretKey)"
orgcurl() { curl -fsS -m 30 -u "$ORG_AUTH" "$@"; }
echo "  org id = $ORG_ID"

g() { local n="$1_$2"; echo "${!n}"; }   # g VAR key → value (bash 3.2 has no assoc arrays)
for p in A B; do
  body="{\"name\":\"isolation-$p-$TS\",\"retention\":0}"
  pj=$(orgcurl -X POST "$HOST/api/public/projects" -H "Content-Type: application/json" -d "$body")
  printf -v "PID_$p" "%s" "$(echo "$pj" | jq -r .id)"
  K=$(orgcurl -X POST "$HOST/api/public/projects/$(g PID $p)/apiKeys" -H "Content-Type: application/json" \
    -d "{\"note\":\"isolation $p\"}")
  printf -v "PAUTH_$p" "%s" "$(echo "$K" | jq -r .publicKey):$(echo "$K" | jq -r .secretKey)"
  printf -v "TID_$p" "%s" "$(openssl rand -hex 16)"
  NANO="$(date +%s)000000000"
  curl -fsS -m 30 -o /dev/null -u "$(g PAUTH $p)" -X POST "$HOST/api/public/otel/v1/traces" \
    -H "Content-Type: application/json" -H "x-langfuse-ingestion-version: 4" \
    -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"isolation\"}}]},
         \"scopeSpans\":[{\"scope\":{\"name\":\"isolation\"},\"spans\":[{\"traceId\":\"$(g TID $p)\",
         \"spanId\":\"$(openssl rand -hex 8)\",\"name\":\"isolation-trace-$p\",\"kind\":1,
         \"startTimeUnixNano\":\"$NANO\",\"endTimeUnixNano\":\"$NANO\"}]}]}]}"
  echo "  project $p id = $(g PID $p)   trace id = $(g TID $p)"
done

# obs_of <key-pair> <trace id> → JSON of the observations the key can read for that trace
obs_of() { curl -s -m 30 -u "$1" "$HOST/api/public/v2/observations?traceId=$2&fields=core"; }
# Ingestion is asynchronous: wait until both traces are readable with their own key.
for p in A B; do
  n=0
  for _ in $(seq 1 40); do
    n=$(obs_of "$(g PAUTH $p)" "$(g TID $p)" | jq '.data|length' 2>/dev/null || echo 0)
    [ "$n" -ge 1 ] 2>/dev/null && break; sleep 3
  done
  [ "$n" -ge 1 ] 2>/dev/null || { echo "✗ trace $p never became readable (observations: $n)"; exit 1; }
done

echo "════ 2. Two local users via POST /api/auth/signup (SCIM has no password field) ════"
USERS=(viewer orgadmin)

for u in "${USERS[@]}"; do
  printf -v "EMAIL_$u" "%s" "$u-$TS@isolation.test"
  # letters + digit + special char satisfy the signup password policy; the value never leaves $WORK.
  printf 'Aa1!%s' "$(openssl rand -hex 12)" > "$WORK/pw-$u"
  jq -n --arg e "$(g EMAIL $u)" --arg n "Isolation $u" --rawfile p "$WORK/pw-$u" \
    '{name:$n,email:$e,password:$p}' | curl -fsS -m 30 -X POST "$HOST/api/auth/signup" \
    -H "Content-Type: application/json" -d @- | jq -r .message
done

# login <user> → fills $WORK/jar-<user>; returns the NextAuth session JSON on stdout
login() {
  local u=$1 jar="$WORK/jar-$1"
  : > "$jar"
  local csrf; csrf=$(curl -fsS -m 30 -c "$jar" -b "$jar" "$HOST/api/auth/csrf" | jq -r .csrfToken)
  curl -sS -m 30 -c "$jar" -b "$jar" -o /dev/null -X POST "$HOST/api/auth/callback/credentials" \
    --data-urlencode "csrfToken=$csrf" --data-urlencode "email=$(g EMAIL $u)" \
    --data-urlencode "password@$WORK/pw-$u" --data-urlencode "callbackUrl=$HOST/" --data-urlencode "json=true"
  curl -fsS -m 30 -b "$jar" -c "$jar" "$HOST/api/auth/session"
}

echo "════ 3. Memberships (org key): viewer = org NONE + project A VIEWER; orgadmin = org ADMIN ════"
for u in "${USERS[@]}"; do
  printf -v "UID__$u" "%s" "$(login "$u" | jq -r '.user.id // empty')"
  [ -n "$(g UID_ $u)" ] || { echo "✗ login failed for $u (no session user)"; exit 1; }
done
orgcurl -X PUT "$HOST/api/public/organizations/memberships" -H "Content-Type: application/json" \
  -d "{\"userId\":\"$(g UID_ viewer)\",\"role\":\"NONE\"}" >/dev/null
orgcurl -X PUT "$HOST/api/public/projects/$PID_A/memberships" -H "Content-Type: application/json" \
  -d "{\"userId\":\"$(g UID_ viewer)\",\"role\":\"VIEWER\"}" >/dev/null
orgcurl -X PUT "$HOST/api/public/organizations/memberships" -H "Content-Type: application/json" \
  -d "{\"userId\":\"$(g UID_ orgadmin)\",\"role\":\"ADMIN\"}" >/dev/null

ORGM=$(orgcurl "$HOST/api/public/organizations/memberships")
role_of() { echo "$1" | jq -r --arg id "$(g UID_ $2)" '[.memberships[]|select(.userId==$id)|.role]|first // "none"'; }
v=$(role_of "$ORGM" viewer);   [ "$v" = NONE ]  && ok=1 || ok=0; row viewer   "org membership (public API)" "$ORG_ID" NONE  "$v" $ok
v=$(role_of "$ORGM" orgadmin); [ "$v" = ADMIN ] && ok=1 || ok=0; row orgadmin "org membership (public API)" "$ORG_ID" ADMIN "$v" $ok
for p in A B; do
  PM=$(orgcurl "$HOST/api/public/projects/$(g PID $p)/memberships")
  exp_v=none; [ "$p" = A ] && exp_v=VIEWER
  v=$(role_of "$PM" viewer);   [ "$v" = "$exp_v" ] && ok=1 || ok=0; row viewer   "project membership (public API)" "$p" "$exp_v" "$v" $ok
  v=$(role_of "$PM" orgadmin); [ "$v" = none ]     && ok=1 || ok=0; row orgadmin "project membership (public API)" "$p" none "$v" $ok
done

# Fresh login so the session reflects the memberships just written.
for u in "${USERS[@]}"; do login "$u" > "$WORK/session-$u.json"; done

echo "════ 4. Project list in the session (what the UI project switcher is built from) ════"
for u in "${USERS[@]}"; do
  for p in A B; do
    inlist=$(jq -r --arg id "$(g PID $p)" --arg org "$ORG_ID" \
      '[.user.organizations[]?|select(.id==$org)|.projects[]?|select(.id==$id)]|length' "$WORK/session-$u.json")
    if [ "$u" = viewer ] && [ "$p" = B ]; then exp=absent; [ "$inlist" = 0 ] && ok=1 || ok=0
    else exp=present; [ "$inlist" = 1 ] && ok=1 || ok=0; fi
    row "$u" "session project list" "$p" "$exp" "$([ "$inlist" = 1 ] && echo present || echo absent)" $ok
  done
done

# trpc_get <user> <procedure> <json-input> → "<http code> <body>" on stdout
trpc_get() {
  curl -sS -m 60 -b "$WORK/jar-$1" -w '\n%{http_code}' -G "$HOST/api/trpc/$2" \
    --data-urlencode "input={\"json\":$3}" | awk 'NR==1{b=$0;next}{print $0" "b}'
}
trpc_post() {
  curl -sS -m 60 -b "$WORK/jar-$1" -w '\n%{http_code}' -X POST "$HOST/api/trpc/$2" \
    -H "Content-Type: application/json" -d "{\"json\":$3}" | awk 'NR==1{b=$0;next}{print $0" "b}'
}
# describe <"code body"> → "HTTP 200" or "HTTP 403 FORBIDDEN"; ok flag is set by the caller
describe() {
  local code=${1%% *} body=${1#* } e
  e=$(echo "$body" | jq -r '.error.json.data.code // empty' 2>/dev/null || true)
  echo "HTTP $code${e:+ $e}"
}

echo "════ 5. tRPC API behind the UI (cookie auth) ════"
for u in "${USERS[@]}"; do
  for p in A B; do
    deny=0; [ "$u" = viewer ] && [ "$p" = B ] && deny=1
    # traces.byId — fetch the trace by id
    r=$(trpc_get "$u" traces.byId "{\"projectId\":\"$(g PID $p)\",\"traceId\":\"$(g TID $p)\"}")
    obs=$(describe "$r")
    if [ $deny = 1 ]; then exp="HTTP 4xx UNAUTHORIZED|FORBIDDEN|NOT_FOUND"
      echo "$obs" | grep -Eq '^HTTP 4[0-9][0-9] (UNAUTHORIZED|FORBIDDEN|NOT_FOUND)$' && ok=1 || ok=0
    else exp="HTTP 200 and the trace id"
      [ "${r%% *}" = 200 ] && [ "$(echo "${r#* }" | jq -r '.result.data.json.id // empty')" = "$(g TID $p)" ] && ok=1 || ok=0
      obs="$obs id=$(echo "${r#* }" | jq -r '.result.data.json.id // "none"')"
    fi
    row "$u" "tRPC traces.byId" "$p" "$exp" "$obs" $ok
    # events.all — the list the v4 UI reads (traces.all returns [] in events_only mode: the traces table stays empty).
    # Positive control: the project's own trace shows up in the list.
    r=$(trpc_get "$u" events.all "{\"projectId\":\"$(g PID $p)\",\"filter\":[],\"orderBy\":null,\"page\":0,\"limit\":50,\"searchQuery\":\"\",\"searchType\":[\"id\"]}")
    obs=$(describe "$r")
    if [ $deny = 1 ]; then exp="HTTP 4xx UNAUTHORIZED|FORBIDDEN|NOT_FOUND"
      echo "$obs" | grep -Eq '^HTTP 4[0-9][0-9] (UNAUTHORIZED|FORBIDDEN|NOT_FOUND)$' && ok=1 || ok=0
    else exp="HTTP 200 and trace in list"
      n=$(echo "${r#* }" | jq -r --arg id "$(g TID $p)" '[.result.data.json.observations[]?|select(.traceId==$id)]|length' 2>/dev/null || echo 0)
      [ "${r%% *}" = 200 ] && [ "$n" = 1 ] && ok=1 || ok=0
      obs="$obs, own trace in list: $n"
    fi
    row "$u" "tRPC events.all (list)" "$p" "$exp" "$obs" $ok
  done
done

echo "════ 6. Write on A (tRPC projectApiKeys.create): VIEWER must be rejected, ADMIN must succeed ════"
r=$(trpc_post viewer projectApiKeys.create "{\"projectId\":\"$PID_A\",\"name\":\"viewer-should-fail\"}")
obs=$(describe "$r")
echo "$obs" | grep -Eq '^HTTP 4[0-9][0-9] (UNAUTHORIZED|FORBIDDEN)$' && ok=1 || ok=0
row viewer "tRPC projectApiKeys.create (mint key)" A "HTTP 403 FORBIDDEN" "$obs" $ok
r=$(trpc_post orgadmin projectApiKeys.create "{\"projectId\":\"$PID_A\",\"name\":\"orgadmin-control\"}")
[ "${r%% *}" = 200 ] && [ -n "$(echo "${r#* }" | jq -r '.result.data.json.id // empty')" ] && ok=1 || ok=0
row orgadmin "tRPC projectApiKeys.create (mint key)" A "HTTP 200 and key id" "$(describe "$r")" $ok
# The viewer's attempt must not have left a key behind.
n=$(orgcurl "$HOST/api/public/projects/$PID_A/apiKeys" | jq '[.apiKeys[]|select(.note=="viewer-should-fail")]|length')
[ "$n" = 0 ] && ok=1 || ok=0
row viewer "key left behind by the rejected call" A "0" "$n" $ok

echo "════ 7. UI pages (cookie auth; the browser check is separate) ════"
# The Next.js page is a static shell: the server does not gate /project/<id>/... by membership, the
# project check happens client-side from the session and tRPC (section 5). So HTTP alone cannot deny;
# what must hold is that the shell carries no data of the other project.
for u in "${USERS[@]}"; do
  for p in A B; do
    for path in "/project/$(g PID $p)" "/project/$(g PID $p)/traces"; do
      out=$(curl -sS -m 60 -b "$WORK/jar-$u" -o "$WORK/ui.html" -w '%{http_code}|%{redirect_url}|%{size_download}' "$HOST$path")
      code=${out%%|*}; rest=${out#*|}; redir=${rest%%|*}; size=${rest#*|}
      leak=$(grep -c "isolation-trace-$p\|$(g TID $p)" "$WORK/ui.html" || true)
      obs="HTTP $code, redirect ${redir:--}, $size bytes, body mentions own trace/name: $leak"
      [ "$code" = 200 ] && [ "$leak" = 0 ] && ok=1 || ok=0
      row "$u" "UI GET ${path#/project/*/}" "$p" "HTTP 200 static shell, no trace data in body" "$obs" $ok
    done
  done
done

echo "════ 8. Public API: project API keys are scoped to their own project ════"
# v4 events_only: GET /api/public/traces and /observations/<id> are switched off (404), so read through
# observations (v2 list). The 404 itself is recorded as a finding: it is not an isolation result.
for p in A B; do
  body=$(curl -s -m 30 -w '\n%{http_code}' -u "$(g PAUTH $p)" "$HOST/api/public/traces/$(g TID $p)")
  code=${body##*$'\n'}
  echo "$body" | grep -q 'events_only' && why=events_only || why=other
  [ "$code" = 404 ] && [ "$why" = events_only ] && ok=1 || ok=0
  row "key $p" "FINDING public GET /traces/<own trace>" $p "404 events_only (endpoint off)" "HTTP $code $why" $ok
done
n=$(obs_of "$PAUTH_A" "$TID_A" | jq '.data|length')
[ "$n" = 1 ] && ok=1 || ok=0; row "key A" "public v2/observations?traceId=<A trace>" A "1 observation" "$n" $ok
n=$(obs_of "$PAUTH_A" "$TID_B" | jq '.data|length')
[ "$n" = 0 ] && ok=1 || ok=0; row "key A" "public v2/observations?traceId=<B trace>" B "0 observations" "$n" $ok
n=$(obs_of "$PAUTH_B" "$TID_B" | jq '.data|length')
[ "$n" = 1 ] && ok=1 || ok=0; row "key B" "public v2/observations?traceId=<B trace>" B "1 observation (control)" "$n" $ok
# Unfiltered list: every row a key can read belongs to its own project (control: at least one row).
for p in A B; do
  other=$([ "$p" = A ] && echo "$PID_B" || echo "$PID_A")
  L=$(curl -s -m 30 -u "$(g PAUTH $p)" "$HOST/api/public/v2/observations?fields=core&limit=100")
  tot=$(echo "$L" | jq '.data|length'); foreign=$(echo "$L" | jq --arg o "$other" '[.data[]|select(.projectId==$o)]|length')
  [ "$tot" -ge 1 ] && [ "$foreign" = 0 ] && ok=1 || ok=0
  row "key $p" "public v2/observations (unfiltered list)" $p ">=1 row, 0 from the other project" "$tot rows, $foreign foreign" $ok
done

echo
echo "════ Result table ════"
{ printf 'actor\tsurface\tproject\texpected\tobserved\tresult\n'; cat "$ROWS"; } | column -t -s $'\t'
echo
TOTAL=$(wc -l < "$ROWS" | tr -d ' ')
if [ "$FAILS" -gt 0 ]; then echo "✗ $FAILS of $TOTAL checks FAILED"; exit 1; fi
echo "✅ all $TOTAL checks passed (org $ORG_ID, projects A=$PID_A B=$PID_B)"
