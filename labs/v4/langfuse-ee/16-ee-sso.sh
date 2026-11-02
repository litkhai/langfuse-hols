#!/usr/bin/env bash
# 16-ee-sso.sh — SSO for self-hosted Langfuse: OIDC, a SAML IdP behind a broker, first-login
# roles, and the switches that force SSO.
#
# Claims under test (each one with a positive and a negative check):
#   A. Keycloak as OIDC provider (AUTH_KEYCLOAK_*): a scripted browser sign-in ends in a
#      Langfuse session; a wrong password does not.
#      A SAML-only IdP (realm `corp`) brokered by Keycloak reaches Langfuse the same way,
#      with the IdP's signature checked.
#      A first-time SSO user gets LANGFUSE_DEFAULT_ORG_ROLE / LANGFUSE_DEFAULT_PROJECT_ROLE
#      (organization NONE + project VIEWER here; project roles need the EE licence).
#      An SSO user whose email already has a password account is refused while account
#      linking is off.
#   B. AUTH_DOMAINS_WITH_SSO_ENFORCEMENT=sso.test: password sign-up and sign-in are refused
#      for that domain only; with AUTH_KEYCLOAK_ALLOW_ACCOUNT_LINKING=true the refused
#      user from A signs in through SSO and the accounts are merged.
#   C. AUTH_DISABLE_USERNAME_PASSWORD=true: password sign-in is refused for every domain,
#      including the initial admin; SSO still works.
# At the end langfuse-web is restarted without the SSO overlay and Keycloak is removed, so
# the initial admin can sign in with a password again.
#
# Requires: EE active (run 05 first), `jq`, `openssl`, `curl`, python3. Keycloak users and all
# passwords are created at run time with a per-run suffix, kept in a mode-700 temp dir and never
# printed.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

for c in jq openssl curl python3; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
KC=http://keycloak:8088
TS=$(date +%Y%m%d%H%M%S)
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
ORG="${LANGFUSE_INIT_ORG_ID:-ch-workshop}"; PROJ="${LANGFUSE_INIT_PROJECT_ID:-llm-observability}"

ROWS="$WORK/rows.tsv"; : > "$ROWS"; FAILS=0
# row <phase> <check> <expected> <observed> <ok:0|1>
row() {
  local res=PASS; [ "$5" = 1 ] || { res=FAIL; FAILS=$((FAILS+1)); }
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$res" >> "$ROWS"
  echo "  $res  $1 | $2 | expected: $3 | observed: $4"
}

# Keycloak's issuer is http://keycloak:8088; on the host that name is pinned to loopback.
kc() { curl -sS -m 30 --resolve keycloak:8088:127.0.0.1 "$@"; }

# phase <enforced domains> <account linking> <disable password>: restart langfuse-web with
# these switches (compose recreates the container when its environment changes).
phase() {
  SSO_ENFORCED_DOMAINS="$1" SSO_ALLOW_ACCOUNT_LINKING="$2" SSO_DISABLE_PASSWORD="$3" \
    lf_compose ee sso -- up -d keycloak langfuse-web >/dev/null 2>&1
  for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$HOST/api/public/health")" = 200 ] && break; sleep 2
  done
  for _ in $(seq 1 90); do
    kc -f -o /dev/null "$KC/realms/langfuse/.well-known/openid-configuration" 2>/dev/null && return 0; sleep 2
  done
  echo "✗ Keycloak did not become ready"; exit 1
}

newpw() { printf 'Aa1!%s' "$(openssl rand -hex 12)" > "$WORK/pw-$1"; }
# kc_user <realm> <email> <first> <last>: create a Keycloak user with the password in $WORK/pw-<email>
kc_user() {
  newpw "$2"
  jq -n --arg e "$2" --arg f "$3" --arg l "$4" --rawfile p "$WORK/pw-$2" \
    '{username:$e,email:$e,emailVerified:true,firstName:$f,lastName:$l,enabled:true,
      credentials:[{type:"password",value:$p,temporary:false}]}' |
    kc -f -o /dev/null -X POST -H "Authorization: Bearer $KTOK" -H "Content-Type: application/json" \
      "$KC/admin/realms/$1/users" -d @-
}

# sso <email> [idp hint] [password file] → JSON {session, final_url, error}
sso() { python3 -I 16-sso-login.py --host "$HOST" --username "$1" --idp-hint "${2:-}" --password-file "${3:-$WORK/pw-$1}"; }

# signup <email> → "<http code> <message>"; the Langfuse password goes to $WORK/pw-local-<email>,
# apart from the Keycloak one in $WORK/pw-<email>
signup() {
  printf 'Aa1!%s' "$(openssl rand -hex 12)" > "$WORK/pw-local-$1"
  jq -n --arg e "$1" --rawfile p "$WORK/pw-local-$1" '{name:"SSO lab",email:$e,password:$p}' |
    curl -sS -m 30 -w '\n%{http_code}' -X POST "$HOST/api/auth/signup" -H "Content-Type: application/json" -d @- |
    awk 'NR==1{b=$0;next}{print $0" "b}' | { read -r code body; echo "$code $(echo "$body" | jq -r '.message // .error // empty' 2>/dev/null)"; }
}

# password_login <email> [password file] → the session email, or "error: <code>"
password_login() {
  local jar="$WORK/jar-pw"; : > "$jar"
  local csrf; csrf=$(curl -fsS -m 30 -c "$jar" -b "$jar" "$HOST/api/auth/csrf" | jq -r .csrfToken)
  local url; url=$(curl -sS -m 30 -c "$jar" -b "$jar" -X POST "$HOST/api/auth/callback/credentials" \
    --data-urlencode "csrfToken=$csrf" --data-urlencode "email=$1" \
    --data-urlencode "password@${2:-$WORK/pw-local-$1}" --data-urlencode "callbackUrl=$HOST/" \
    --data-urlencode "json=true" | jq -r '.url // empty')
  local email; email=$(curl -fsS -m 30 -b "$jar" "$HOST/api/auth/session" | jq -r '.user.email // empty')
  if [ -n "$email" ]; then echo "$email"
  else echo "error: $(python3 -I -c 'import sys,urllib.parse as u; print(u.parse_qs(u.urlparse(sys.argv[1]).query).get("error",["none"])[0])' "$url")"; fi
}

roles_of() {  # roles_of <session JSON> → "org=<role> project=<role>"
  echo "$1" | jq -r --arg o "$ORG" --arg p "$PROJ" \
    '[.session.user.organizations[]?|select(.id==$o)] as $org
     | "org=\($org[0].role // "none") project=\(([$org[0].projects[]?|select(.id==$p)|.role]|first) // "none")"'
}

BOB="bob-$TS@sso.test"; DAVE="dave-$TS@sso.test"; ALICE="alice-$TS@sso.test"
ERIN="erin-$TS@sso.test"; FRANK="frank-$TS@other.test"; GRACE="grace-$TS@other.test"

echo "════ A. OIDC + SAML broker, no enforcement ════"
phase "" false false
KTOK=$(kc -f -d grant_type=password -d client_id=admin-cli -d username=admin \
  --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD:-admin}" \
  "$KC/realms/master/protocol/openid-connect/token" | jq -r .access_token)
kc_user langfuse "$BOB" Bob Oidc
kc_user langfuse "$DAVE" Dave Linked
kc_user corp "$ALICE" Alice Saml

# Check the corp IdP's signature: put the realm's signing certificate on the broker.
CERT=$(kc -f "$KC/realms/corp/protocol/saml/descriptor" |
  python3 -I -c 'import sys,re; print(re.search(r"<ds:X509Certificate>([^<]+)</ds:X509Certificate>", sys.stdin.read()).group(1))')
IDP="$KC/admin/realms/langfuse/identity-provider/instances/corp-saml"
kc -f -H "Authorization: Bearer $KTOK" "$IDP" |
  jq --arg c "$CERT" '.config.validateSignature="true" | .config.signingCertificate=$c' |
  kc -f -o /dev/null -X PUT -H "Authorization: Bearer $KTOK" -H "Content-Type: application/json" "$IDP" -d @-
v=$(kc -f -H "Authorization: Bearer $KTOK" "$IDP" | jq -r .config.validateSignature)
[ "$v" = true ] && ok=1 || ok=0; row A "broker checks the SAML signature" "validateSignature=true" "validateSignature=$v" $ok

P=$(curl -fsS -m 30 "$HOST/api/auth/providers" | jq -r 'keys|join(",")')
echo "$P" | grep -q keycloak && ok=1 || ok=0; row A "/api/auth/providers" "keycloak listed" "$P" $ok

R=$(sso "$BOB")
e=$(echo "$R" | jq -r '.session.user.email // "none"'); [ "$e" = "$BOB" ] && ok=1 || ok=0
row A "OIDC sign-in (Keycloak)" "session for bob" "session=$e error=$(echo "$R" | jq -r '.error // "none"')" $ok
r=$(roles_of "$R"); [ "$r" = "org=NONE project=VIEWER" ] && ok=1 || ok=0
row A "first-login roles (LANGFUSE_DEFAULT_*)" "org=NONE project=VIEWER" "$r" $ok

printf 'Aa1!wrong-%s' "$(openssl rand -hex 6)" > "$WORK/pw-wrong"
# What Langfuse keeps from the IdP: NextAuth's Account row (tokens unless AUTH_IGNORE_ACCOUNT_FIELDS).
# A value starting with `eyJ` is a JWT as issued (base64url of `{"`), i.e. not encrypted by Langfuse.
# Only the first three characters are read; no token is printed.
tok=$(lf_compose -- exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tA -c \
  "SELECT concat_ws(',', CASE WHEN left(a.access_token, 3) = 'eyJ' THEN 'access_token' END,
     CASE WHEN left(a.refresh_token, 3) = 'eyJ' THEN 'refresh_token' END, CASE WHEN left(a.id_token, 3) = 'eyJ' THEN 'id_token' END)
   FROM \"Account\" a JOIN users u ON u.id = a.user_id WHERE u.email = '$BOB' AND a.provider = 'keycloak'")
[ -n "$tok" ] && ok=1 || ok=0
row A "IdP tokens in Postgres \"Account\" as plain JWTs (no AUTH_IGNORE_ACCOUNT_FIELDS)" "recorded" "${tok:-none}" $ok

R=$(sso "$BOB" "" "$WORK/pw-wrong")
e=$(echo "$R" | jq -r '.session.user.email // "none"'); [ "$e" = none ] && ok=1 || ok=0
row A "OIDC sign-in, wrong password" "no session" "session=$e error=$(echo "$R" | jq -r '.error // "none"')" $ok

R=$(sso "$ALICE" corp-saml)
e=$(echo "$R" | jq -r '.session.user.email // "none"'); [ "$e" = "$ALICE" ] && ok=1 || ok=0
row A "SAML IdP via broker (kc_idp_hint)" "session for alice" "session=$e error=$(echo "$R" | jq -r '.error // "none"')" $ok
AID=$(kc -f -H "Authorization: Bearer $KTOK" "$KC/admin/realms/langfuse/users?email=$ALICE&exact=true" | jq -r '.[0].id // empty')
fi_=$(kc -f -H "Authorization: Bearer $KTOK" "$KC/admin/realms/langfuse/users/$AID/federated-identity" | jq -r '[.[].identityProvider]|join(",")')
[ "$fi_" = corp-saml ] && ok=1 || ok=0; row A "broker user linked to the SAML IdP" "corp-saml" "${fi_:-none}" $ok

s=$(signup "$DAVE"); [ "${s%% *}" = 200 ] && ok=1 || ok=0
row A "password sign-up (control, no enforcement yet)" "HTTP 200" "HTTP $s" $ok
R=$(sso "$DAVE")
e=$(echo "$R" | jq -r '.session.user.email // "none"'); err=$(echo "$R" | jq -r '.error // "none"')
[ "$e" = none ] && [ "$err" = OAuthAccountNotLinked ] && ok=1 || ok=0
row A "SSO for an email that has a password account, linking off" "no session, OAuthAccountNotLinked" "session=$e error=$err" $ok

echo "════ B. AUTH_DOMAINS_WITH_SSO_ENFORCEMENT=sso.test, account linking on ════"
phase sso.test true false
s=$(signup "$ERIN"); [ "${s%% *}" != 200 ] && ok=1 || ok=0
row B "password sign-up, enforced domain" "refused" "HTTP $s" $ok
s=$(signup "$FRANK"); [ "${s%% *}" = 200 ] && ok=1 || ok=0
row B "password sign-up, other domain (control)" "HTTP 200" "HTTP $s" $ok
l=$(password_login "$DAVE"); [ "$l" != "$DAVE" ] && ok=1 || ok=0
row B "password sign-in, enforced domain (existing account)" "no session" "$l" $ok
l=$(password_login "$FRANK"); [ "$l" = "$FRANK" ] && ok=1 || ok=0
row B "password sign-in, other domain (control)" "session" "$l" $ok
R=$(sso "$DAVE")
e=$(echo "$R" | jq -r '.session.user.email // "none"'); [ "$e" = "$DAVE" ] && ok=1 || ok=0
row B "SSO for the same email, linking on" "session for dave" "session=$e error=$(echo "$R" | jq -r '.error // "none"')" $ok
acc=$(lf_compose -- exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tA -c \
  "SELECT string_agg(a.provider, ',') FROM \"Account\" a JOIN users u ON u.id = a.user_id WHERE u.email = '$DAVE'")
[ "$acc" = keycloak ] && ok=1 || ok=0; row B "accounts linked to dave's user (Postgres)" "keycloak" "${acc:-none}" $ok

echo "════ C. AUTH_DISABLE_USERNAME_PASSWORD=true ════"
phase "" false true
s=$(signup "$GRACE"); [ "${s%% *}" != 200 ] && ok=1 || ok=0
row C "password sign-up, any domain" "refused" "HTTP $s" $ok
l=$(password_login "$FRANK"); [ "$l" != "$FRANK" ] && ok=1 || ok=0
row C "password sign-in, other domain" "no session" "$l" $ok
printf '%s' "${LANGFUSE_INIT_USER_PASSWORD:?set LANGFUSE_INIT_USER_PASSWORD in _base/.env}" > "$WORK/pw-admin"
ADMIN_EMAIL="${LANGFUSE_INIT_USER_EMAIL:-admin@example.com}"
l=$(password_login "$ADMIN_EMAIL" "$WORK/pw-admin"); [ "$l" != "$ADMIN_EMAIL" ] && ok=1 || ok=0
row C "password sign-in, initial admin" "no session" "$l" $ok
R=$(sso "$BOB")
e=$(echo "$R" | jq -r '.session.user.email // "none"'); [ "$e" = "$BOB" ] && ok=1 || ok=0
row C "OIDC sign-in still works" "session for bob" "session=$e" $ok

echo "════ Restore: langfuse-web without the SSO overlay, Keycloak removed ════"
lf_compose ee -- up -d langfuse-web >/dev/null 2>&1
lf_compose ee sso -- rm -sf keycloak >/dev/null 2>&1
for _ in $(seq 1 90); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$HOST/api/public/health")" = 200 ] && break; sleep 2
done
l=$(password_login "$ADMIN_EMAIL" "$WORK/pw-admin"); [ "$l" = "$ADMIN_EMAIL" ] && ok=1 || ok=0
row restore "password sign-in, initial admin" "session" "$l" $ok

echo
echo "════ Summary ════"
column -t -s $'\t' "$ROWS"
echo
if [ "$FAILS" = 0 ]; then echo "✅ all $(wc -l < "$ROWS" | tr -d ' ') checks passed"; else echo "✗ $FAILS check(s) failed"; exit 1; fi
