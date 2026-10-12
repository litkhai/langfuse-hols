#!/usr/bin/env bash
# 15-ch-row-policy.sh — ClickHouse OSS row policies on the Langfuse v4 tables, end to end.
#
# Question: Langfuse's server-side data masking is EE; can plain ClickHouse OSS give a
# directly connected analyst a per-project view of the data?
#
#   1. Row policies (`project_id = '<A>'`) limit a read-only user to project A ........ works on OSS
#   2. The account Langfuse itself uses is unaffected and the public API keeps working . checked
#   3. Escape hatches (remote(), merge(), views, system.parts) ........................ probed
#   4. CREATE MASKING POLICY (column masking in ClickHouse) ........................... Cloud only
#
# Every check prints PASS/FAIL with the observed value and has a positive control (the same
# query as the Langfuse account), so a 0 means something. Exit 1 if any check fails.
# The analyst user and the row policies are dropped on exit (also on failure); the org and
# the two projects stay.
#
# Requires: EE overlay up (`EE=1 _base/bin/up.sh v4`), ADMIN_API_KEY in _base/.env, `jq`,
# the langfuse SDK in .venv-v4. Takes about a minute.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "✗ please install jq"; exit 1; }
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
ADMIN="Authorization: Bearer ${ADMIN_API_KEY:?set ADMIN_API_KEY in _base/.env}"
CH_USER="${CLICKHOUSE_USER:-clickhouse}"
CH_PASSWORD="${CLICKHOUSE_PASSWORD:-clickhouse}"
STAMP="$(date +%Y%m%d%H%M%S)"
POLICY="rp_analyst_a"
ANALYST="analyst_a"
ANALYST_PW="$(openssl rand -hex 12)"
# The stack's own account ($CH_USER) has access_management=0 (shown in step 4), so it cannot run
# CREATE USER / CREATE ROW POLICY. A second, temporary admin user does that; it exists only for this run.
ADMIN_CH="lab_rp_admin"
ADMIN_PW="$(openssl rand -hex 12)"
ADMIN_XML="/etc/clickhouse-server/users.d/zz-15-row-policy-admin.xml"

PY="python"
if [[ -n "${VIRTUAL_ENV:-}" && -x "$VIRTUAL_ENV/bin/python" ]]; then PY="$VIRTUAL_ENV/bin/python"
elif [[ -x ../../../.venv-v4/bin/python ]]; then PY="../../../.venv-v4/bin/python"
elif command -v python3 >/dev/null 2>&1; then PY="python3"
fi

# ch      — as the Langfuse account (full access);  ach — as the analyst.
ch()  { lf_compose -- exec -T clickhouse clickhouse-client -u "$CH_USER" --password "$CH_PASSWORD" "$@"; }
adm() { lf_compose -- exec -T clickhouse clickhouse-client -u "$ADMIN_CH" --password "$ADMIN_PW" "$@"; }
ach() { lf_compose -- exec -T clickhouse clickhouse-client -u "$ANALYST" --password "$ANALYST_PW" "$@"; }

FAILS=0
check() {  # $1=PASS|FAIL  $2=description  $3=observed
  printf '  %s  %s  [%s]\n' "$1" "$2" "$3"
  [[ "$1" == PASS ]] || FAILS=$((FAILS + 1))
}
expect_eq() {  # $1=description  $2=expected  $3=observed
  if [[ "$2" == "$3" ]]; then check PASS "$1" "$3"; else check FAIL "$1 (expected: $2)" "$3"; fi
}

TABLES=()
cleanup() {
  set +e
  if [[ ${#TABLES[@]} -gt 0 ]]; then
    local on=""; for t in "${TABLES[@]}"; do on+="${on:+, }default.$t"; done
    adm -q "DROP ROW POLICY IF EXISTS $POLICY ON $on" >/dev/null 2>&1
  fi
  adm -q "DROP USER IF EXISTS $ANALYST" >/dev/null 2>&1
  echo "▶ Cleanup: row policies left = $(ch -q "SELECT count() FROM system.row_policies WHERE name LIKE '%$POLICY%'" 2>/dev/null)," \
       "users named $ANALYST left = $(ch -q "SELECT count() FROM system.users WHERE name = '$ANALYST'" 2>/dev/null)"
  lf_compose -- exec -T clickhouse rm -f "$ADMIN_XML" >/dev/null 2>&1
  echo "▶ Cleanup: temporary admin user definition removed ($ADMIN_XML); ClickHouse drops it on its next config reload"
}
trap cleanup EXIT

echo "════ 0. Server and the tables that carry project_id ════"
echo "  version: $(ch -q 'SELECT version()')"
# Physical tables only: a row policy on a view or a MaterializedView does not guard its storage.
# (no mapfile/declare -A: this must also run under macOS bash 3.2)
while IFS= read -r l; do [[ -n "$l" ]] && TABLES+=("$l"); done < <(ch -q "SELECT t.name FROM system.tables t INNER JOIN system.columns c
  ON c.database = t.database AND c.table = t.name
  WHERE t.database = 'default' AND c.name = 'project_id' AND t.engine NOT IN ('View', 'MaterializedView')
  ORDER BY t.name FORMAT TSV")
VIEWS=()
while IFS= read -r l; do [[ -n "$l" ]] && VIEWS+=("$l"); done < <(ch -q "SELECT t.name FROM system.tables t INNER JOIN system.columns c
  ON c.database = t.database AND c.table = t.name
  WHERE t.database = 'default' AND c.name = 'project_id' AND t.engine IN ('View', 'MaterializedView')
  ORDER BY t.name FORMAT TSV")
echo "  tables with project_id (${#TABLES[@]}): ${TABLES[*]}"
echo "  views with project_id  (${#VIEWS[@]}): ${VIEWS[*]}   (not given a policy; they read the tables above)"
echo "  tables WITHOUT project_id: $(ch -q "SELECT arrayStringConcat(groupArray(name), ' ') FROM system.tables
  WHERE database = 'default' AND name NOT IN (SELECT table FROM system.columns WHERE database = 'default' AND name = 'project_id')")"

echo "════ 1. Organization + two projects (A, B) + keys ════"
ORG_ID=$(curl -fsS --max-time 30 -X POST "${HOST}/api/admin/organizations" -H "$ADMIN" -H "Content-Type: application/json" \
  -d "{\"name\":\"rowpolicy-$STAMP\"}" | jq -r '.id')
ORG_KEY=$(curl -fsS --max-time 30 -X POST "${HOST}/api/admin/organizations/${ORG_ID}/apiKeys" -H "$ADMIN" \
  -H "Content-Type: application/json" -d '{"note":"row policy lab"}')
ORG_PK=$(jq -r '.publicKey' <<<"$ORG_KEY"); ORG_SK=$(jq -r '.secretKey' <<<"$ORG_KEY")
orgcurl() { curl -fsS --max-time 30 -u "${ORG_PK}:${ORG_SK}" "$@"; }
for p in A B; do
  id=$(orgcurl -X POST "${HOST}/api/public/projects" -H "Content-Type: application/json" \
    -d "{\"name\":\"rowpolicy-$STAMP-$p\",\"retention\":0}" | jq -r '.id')
  k=$(orgcurl -X POST "${HOST}/api/public/projects/${id}/apiKeys" -H "Content-Type: application/json" -d '{"note":"row policy lab"}')
  printf -v "PID_$p" '%s' "$id"
  printf -v "PPK_$p" '%s' "$(jq -r '.publicKey' <<<"$k")"
  printf -v "PSK_$p" '%s' "$(jq -r '.secretKey' <<<"$k")"
  echo "  project $p id = $id"
done
A="$PID_A"; B="$PID_B"
pk() { local v="P$1_$2"; printf '%s' "${!v}"; }   # pk PK|SK A|B

send_traces() {  # $1=A|B  $2=count  — OTLP traces + one score each, flushed
  LANGFUSE_HOST="$HOST" LANGFUSE_PUBLIC_KEY="$(pk PK "$1")" LANGFUSE_SECRET_KEY="$(pk SK "$1")" \
  "$PY" - "$1" "$2" <<'PY'
import sys
from langfuse import Langfuse, get_client, propagate_attributes
tag, n = sys.argv[1], int(sys.argv[2])
Langfuse()
lf = get_client()
assert lf.auth_check(), "auth check failed"
for i in range(n):
    with lf.start_as_current_observation(as_type="span", name=f"rowpolicy-{tag}", input={"q": f"hello {tag} {i}"}) as root:
        with propagate_attributes(trace_name=f"rowpolicy-{tag}", user_id=f"user_{tag}"):
            tid = lf.get_current_trace_id()
            with lf.start_as_current_observation(as_type="generation", name="answer", model="gpt-4o-mini",
                                                 input=[{"role": "user", "content": f"hi {tag}"}]) as gen:
                gen.update(output=f"reply {tag} {i}", usage_details={"input": 10, "output": 5})
        root.update(output={"a": f"reply {tag} {i}"})
    lf.create_score(name="rowpolicy", trace_id=tid, value=1, data_type="BOOLEAN")
lf.flush()
print(f"  sent {n} traces (+{n} scores) to project {tag}")
PY
}
echo "════ 2. Send traces to A and B through the SDK (OTLP) ════"
send_traces A 3
send_traces B 3

echo "▶ Waiting for both projects' rows in events_full and scores (up to 120 s)…"
for i in $(seq 1 40); do
  nA=$(ch -q "SELECT count() FROM default.events_full WHERE project_id='$A'")
  nB=$(ch -q "SELECT count() FROM default.events_full WHERE project_id='$B'")
  sA=$(ch -q "SELECT count() FROM default.scores WHERE project_id='$A'")
  sB=$(ch -q "SELECT count() FROM default.scores WHERE project_id='$B'")
  [[ "$nA" -ge 6 && "$nB" -ge 6 && "$sA" -ge 3 && "$sB" -ge 3 ]] && break
  sleep 3
done
echo "  events_full: A=$nA B=$nB   scores: A=$sA B=$sB"

echo "════ 3. Which tables hold rows for both projects (positive control, as $CH_USER) ════"
TESTED=()
for t in "${TABLES[@]}" "${VIEWS[@]}"; do
  [[ "$t" == events_core_mv ]] && continue
  ca=$(ch -q "SELECT count() FROM default.$t WHERE project_id='$A'"); cb=$(ch -q "SELECT count() FROM default.$t WHERE project_id='$B'")
  if [[ "$ca" -gt 0 && "$cb" -gt 0 ]]; then TESTED+=("$t"); echo "  tested   $t  (A=$ca, B=$cb)"
  else echo "  skipped  $t  (A=$ca, B=$cb: no rows for one project, a 0 here would prove nothing)"; fi
done
[[ " ${TESTED[*]} " == *" events_full "* ]] || { echo "✗ events_full has no rows for both projects"; exit 1; }

obs() { curl -fsS --max-time 30 -u "$(pk PK "$1"):$(pk SK "$1")" "${HOST}/api/public/v2/observations?limit=100" | jq -r '.data | length'; }
OBS_A_BEFORE=$(obs A); OBS_B_BEFORE=$(obs B)

echo "════ 4. Create $ANALYST and a row policy on every project_id table ════"
echo "  $CH_USER: access_management = $(lf_compose -- exec -T clickhouse sh -c "grep -o '<access_management>[01]' /etc/clickhouse-server/users.d/default-user.xml" | sed 's/<access_management>//') (users.d/default-user.xml)"
if ch -q "CREATE USER probe_should_fail" >/dev/null 2>&1; then ch -q "DROP USER probe_should_fail"; check FAIL "$CH_USER cannot manage access" "it can"
else check PASS "$CH_USER cannot create users (Langfuse's account has no access management)" "ACCESS_DENIED"; fi
echo "  → creating a temporary admin user $ADMIN_CH through users.d (ClickHouse reloads it, no restart)"
lf_compose -- exec -T clickhouse sh -c "cat > $ADMIN_XML" <<XML
<clickhouse><users><$ADMIN_CH>
  <profile>default</profile><quota>default</quota><access_management>1</access_management>
  <networks><ip>127.0.0.1</ip><ip>::1</ip></networks>
  <password><![CDATA[$ADMIN_PW]]></password>
</$ADMIN_CH></users></clickhouse>
XML
for i in $(seq 1 30); do adm -q "SELECT 1" >/dev/null 2>&1 && break; sleep 2; [[ $i -eq 30 ]] && { echo "✗ temporary admin user did not appear"; exit 1; }; done
adm -q "DROP USER IF EXISTS $ANALYST"
adm -q "CREATE USER $ANALYST IDENTIFIED BY '$ANALYST_PW'"
adm -q "GRANT SELECT ON default.* TO $ANALYST"
ON=""; for t in "${TABLES[@]}"; do ON+="${ON:+, }default.$t"; done
adm -q "DROP ROW POLICY IF EXISTS $POLICY ON $ON"
adm -q "CREATE ROW POLICY $POLICY ON $ON USING project_id = '$A' TO $ANALYST"
echo "  $(ch -q "SELECT count() FROM system.row_policies WHERE short_name = '$POLICY'") policies named $POLICY; one of them:"
ch -q "SELECT database, table, select_filter, apply_to_list FROM system.row_policies WHERE short_name = '$POLICY' AND table = 'events_full' FORMAT Vertical" | sed 's/^/    /'

echo "════ 5. As $ANALYST: only project A; as $CH_USER: both ════"
for t in "${TESTED[@]}"; do
  full=$(ch -q "SELECT project_id, count() FROM default.$t WHERE project_id IN ('$A','$B') GROUP BY project_id ORDER BY project_id FORMAT TSV" | tr '\t\n' ': ' )
  expA=$(ch -q "SELECT count() FROM default.$t WHERE project_id='$A'")
  got=$(ach -q "SELECT project_id, count() FROM default.$t GROUP BY project_id ORDER BY project_id FORMAT TSV" 2>&1 | tr '\t\n' ': ')
  expect_eq "$t: $CH_USER sees A and B (control)" "$(printf '%s:%s %s:%s' "$A" "$expA" "$B" "$(ch -q "SELECT count() FROM default.$t WHERE project_id='$B'")")" "${full% }"
  expect_eq "$t: $ANALYST GROUP BY project_id sees only A" "$A:$expA" "${got% }"
  expect_eq "$t: $ANALYST WHERE project_id='B' returns 0" "0" "$(ach -q "SELECT count() FROM default.$t WHERE project_id='$B'" 2>&1)"
done

echo "════ 6. Why $CH_USER is unaffected (settings) ════"
echo "  system.settings (per query, user-level):"
ch -q "SELECT name, value FROM system.settings WHERE name ILIKE '%row_polic%' FORMAT TSV" | sed 's/^/    /'
echo "  system.server_settings rows matching row_polic|users_without: $(ch -q "SELECT count() FROM system.server_settings WHERE name ILIKE '%row_polic%' OR name ILIKE '%users_without%'")  (the server option is not listed there)"
echo "  config.xml (<access_control_improvements>), effective copy first:"
CFG=$(lf_compose -- exec -T clickhouse sh -c 'grep -Hn "users_without_row_policies_can_read_rows\|throw_on_unmatched_row_policies" /var/lib/clickhouse/preprocessed_configs/config.xml /etc/clickhouse-server/config.xml 2>/dev/null' || true)
printf '%s\n' "$CFG" | sed 's/^/    /'
echo "  $CH_USER has policies applied to it: $(ch -q "SELECT count() FROM system.row_policies WHERE short_name = '$POLICY' AND has(apply_to_list, '$CH_USER')") (policy lists only $ANALYST)"
if grep -q "users_without_row_policies_can_read_rows>true<" <<<"$CFG"; then
  check PASS "users_without_row_policies_can_read_rows is true: a user the policy does not name reads all rows" "true"
else
  check FAIL "users_without_row_policies_can_read_rows could not be read as true" "see grep above"
fi

echo "════ 7. Langfuse itself still works after the policies exist ════"
# v4 runs in events_only mode: GET /api/public/traces answers 404 there (checked, see README), so the
# readable public endpoint is /api/public/v2/observations (reads events_*). Two observations per trace.
obs() { curl -fsS --max-time 30 -u "$(pk PK "$1"):$(pk SK "$1")" "${HOST}/api/public/v2/observations?limit=100" | jq -r '.data | length'; }
echo "  control — API before the policy was created: A=$OBS_A_BEFORE B=$OBS_B_BEFORE"
expect_eq "control: the API returned B's 6 observations BEFORE the policies existed" "6" "$OBS_B_BEFORE"
expect_eq "public API GET /api/public/v2/observations, project B, AFTER the policies" "6" "$(obs B)"
expect_eq "public API GET /api/public/v2/observations, project A, AFTER the policies" "6" "$(obs A)"
send_traces B 1
for i in $(seq 1 40); do [[ "$(obs B)" == "8" ]] && break; sleep 3; done
expect_eq "a trace sent AFTER the policies exist is ingested (worker insert) and served to B" "8" "$(obs B)"
expect_eq "…and ClickHouse holds 8 events_full rows for B ($CH_USER)" "8" "$(ch -q "SELECT count() FROM default.events_full WHERE project_id='$B'")"

echo "════ 8. Escape hatches as $ANALYST ════"
# leak_check DESC SQL_ANALYST SQL_CONTROL — SQL must output "<project_id>\t<count>" rows. PASS = no row of B comes back.
# A query refused with an error is a blocked path; the error text is shown.
leak_check() {
  local desc="$1" qa="$2" qc="$3" out ctl
  ctl=$(ch -q "$qc" 2>&1 | tr '\t\n' ': ')
  if out=$(ach -q "$qa" 2>&1); then
    if grep -q "$B" <<<"$out"; then check FAIL "$desc: B rows visible" "$(tr '\t\n' ': ' <<<"$out")"
    else check PASS "$desc: no B rows" "analyst: $(tr '\t\n' ': ' <<<"$out")| control: $ctl"; fi
  else
    check PASS "$desc: refused" "$(grep -o 'Code: [0-9]*\.[^(]*([A-Z_]*)' <<<"$out" | head -1)"
  fi
}
G="GROUP BY project_id ORDER BY project_id FORMAT TSV"
leak_check "merge('default','^events_full\$')" \
  "SELECT project_id, count() FROM merge('default', '^events_full\$') $G" \
  "SELECT project_id, count() FROM merge('default', '^events_full\$') WHERE project_id IN ('$A','$B') $G"
leak_check "MV target events_core directly" \
  "SELECT project_id, count() FROM default.events_core $G" \
  "SELECT project_id, count() FROM default.events_core WHERE project_id IN ('$A','$B') $G"
leak_check "remote('localhost') without credentials" \
  "SELECT project_id, count() FROM remote('localhost', default.events_full) $G" \
  "SELECT project_id, count() FROM remote('localhost', default.events_full, '$CH_USER', '$CH_PASSWORD') WHERE project_id IN ('$A','$B') $G"
leak_check "remote('localhost') with the analyst's own credentials" \
  "SELECT project_id, count() FROM remote('localhost', default.events_full, '$ANALYST', '$ANALYST_PW') $G" \
  "SELECT project_id, count() FROM remote('localhost', default.events_full, '$CH_USER', '$CH_PASSWORD') WHERE project_id IN ('$A','$B') $G"
leak_check "FINAL" \
  "SELECT project_id, count() FROM default.events_full FINAL $G" \
  "SELECT project_id, count() FROM default.events_full FINAL WHERE project_id IN ('$A','$B') $G"
leak_check "PREWHERE on another column" \
  "SELECT project_id, count() FROM default.events_full PREWHERE trace_id != '' $G" \
  "SELECT project_id, count() FROM default.events_full PREWHERE trace_id != '' WHERE project_id IN ('$A','$B') $G"
# The analyst has no REMOTE grant (a table-function privilege, not covered by SELECT ON default.*), so the two
# remote() cases above were refused. Grant it (remote() also needs CREATE TEMPORARY TABLE) and try again: the second hop runs as the user named in the call.
adm -q "GRANT REMOTE, CREATE TEMPORARY TABLE ON *.* TO $ANALYST"
leak_check "remote('localhost') without credentials, REMOTE granted" \
  "SELECT project_id, count() FROM remote('localhost', default.events_full) $G" \
  "SELECT project_id, count() FROM remote('localhost', default.events_full, '$CH_USER', '$CH_PASSWORD') WHERE project_id IN ('$A','$B') $G"
leak_check "remote('localhost') with the analyst's own credentials, REMOTE granted" \
  "SELECT project_id, count() FROM remote('localhost', default.events_full, '$ANALYST', '$ANALYST_PW') $G" \
  "SELECT project_id, count() FROM remote('localhost', default.events_full, '$CH_USER', '$CH_PASSWORD') WHERE project_id IN ('$A','$B') $G"
adm -q "REVOKE REMOTE, CREATE TEMPORARY TABLE ON *.* FROM $ANALYST"
# system.parts is metadata: it carries row counts per table but not per project, and needs its own grant.
leak_check "system.parts (row counts of the whole table)" \
  "SELECT toString(sum(rows)), 0 FROM system.parts WHERE database='default' AND table='events_full' AND active FORMAT TSV" \
  "SELECT 'all projects', sum(rows) FROM system.parts WHERE database='default' AND table='events_full' AND active FORMAT TSV"
echo "  (system.parts is not a row-policy question: it carries no project_id. It is blocked or open by GRANT, shown above.)"

echo "════ 9. CREATE MASKING POLICY on OSS ════"
echo "  version: $(ch -q 'SELECT version()')"
MP_OUT=$(adm -q "CREATE MASKING POLICY mp_probe ON default.events_full UPDATE input = '***' TO $ANALYST" 2>&1 || true)
echo "$MP_OUT" | sed 's/^/    /'
if grep -q "Code: 344" <<<"$MP_OUT" && grep -q "SUPPORT_IS_DISABLED" <<<"$MP_OUT"; then
  check PASS "CREATE MASKING POLICY is refused on this server" "$(grep -o 'Code: [0-9]*\.[^(]*([A-Z_]*)' <<<"$MP_OUT" | tail -1 | sed 's/DB::Exception: Received from [^:]*:[0-9]*\. DB::Exception: //')"
else
  check FAIL "CREATE MASKING POLICY was expected to be refused with Code 344 SUPPORT_IS_DISABLED" "$MP_OUT"
fi
expect_eq "no masking policy was created (control: row policies exist, masking ones do not)" "0" \
  "$(ch -q "SELECT count() FROM system.row_policies WHERE short_name = 'mp_probe'")"

echo
if [[ "$FAILS" -eq 0 ]]; then echo "✅ ROW POLICY VERDICT: PASS (0 failed checks)"; else echo "✗ ROW POLICY VERDICT: FAIL ($FAILS failed checks)"; exit 1; fi
