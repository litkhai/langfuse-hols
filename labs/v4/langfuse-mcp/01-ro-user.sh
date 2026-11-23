#!/usr/bin/env bash
# 01-ro-user.sh — create the read-only ClickHouse user lab_mcp_ro on the shared v4 stack
# and prove it is read-only. Idempotent: re-running keeps the password in .run/ch-ro.env.
#
#   1. render clickhouse/lab_mcp_ro.xml.template (sha256 of a random password) into the
#      container's users.d; wait until ClickHouse has loaded it
#   2. SHOW GRANTS / the settings profile as the server sees them
#   3. negative checks as lab_mcp_ro: INSERT, CREATE, SELECT input, another database,
#      raising max_execution_time — each must fail with the expected error code
#   4. positive controls: the same INSERT as admin into the lab database succeeds; the
#      same SELECT input as admin returns a value; SELECT of an allowed column as lab_mcp_ro works
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"

if [[ ! -f "$RUN_DIR/ch-ro.env" ]]; then
  ( umask 077; printf 'CLICKHOUSE_RO_PASSWORD=%s\n' "$(openssl rand -hex 16)" > "$RUN_DIR/ch-ro.env" )
fi
PW="$(sed -n 's/^CLICKHOUSE_RO_PASSWORD=//p' "$RUN_DIR/ch-ro.env")"
HASH="$(printf '%s' "$PW" | shasum -a 256 | cut -d' ' -f1)"
sed "s/@PASSWORD_SHA256@/$HASH/" "$LAB_DIR/clickhouse/lab_mcp_ro.xml.template" > "$RUN_DIR/lab_mcp_ro.xml"
docker cp -q "$RUN_DIR/lab_mcp_ro.xml" "$CH_CONTAINER:/etc/clickhouse-server/users.d/lab_mcp_ro.xml"
for i in $(seq 1 30); do
  ch_admin -q "SELECT count() FROM system.users WHERE name='$RO_USER'" | grep -qx 1 && break
  sleep 1
done
ch_admin -q "SELECT count() FROM system.users WHERE name='$RO_USER'" | grep -qx 1 \
  || { echo "✗ $RO_USER not loaded from users.d" >&2; exit 1; }
echo "✓ $RO_USER loaded (storage: $(ch_admin -q "SELECT storage FROM system.users WHERE name='$RO_USER'"))"

# The stack's admin user has no SHOW USERS grant, so the user reads its own grants and settings.
echo; echo "── SHOW GRANTS (as $RO_USER)"
ch_ro -q "SHOW GRANTS"
echo; echo "── settings from lab_mcp_ro_profile (as $RO_USER)"
ch_ro -q "SELECT name, value FROM system.settings WHERE name IN ('readonly','max_execution_time','max_result_rows','result_overflow_mode','max_rows_to_read','max_memory_usage') ORDER BY name FORMAT PrettyCompactMonoBlock"

ch_admin -q "CREATE DATABASE IF NOT EXISTS $LAB_DB"
ch_admin -q "CREATE TABLE IF NOT EXISTS $LAB_DB.write_probe (t DateTime, who String) ENGINE=MergeTree ORDER BY t"

fails=0
expect_fail() {  # expect_fail <label> <error code> <sql>
  local out
  if out="$(ch_ro -q "$3" </dev/null 2>&1)"; then
    echo "✗ $1: succeeded, expected Code: $2"; fails=$((fails+1))
  elif grep -q "Code: $2\." <<<"$out"; then
    echo "✓ $1: Code $2: $(sed -n 's/.*Received from [^ ]* DB::Exception: //p' <<<"$out" | head -1 | cut -c1-150)"
  else
    echo "✗ $1: failed with another error: $(head -c 200 <<<"$out")"; fails=$((fails+1))
  fi
}
expect_ok() {  # expect_ok <label> <runner> <sql>
  local out
  if out="$($2 -q "$3" </dev/null 2>&1)"; then echo "✓ $1: $(head -c 80 <<<"$out" | tr '\n' ' ')"
  else echo "✗ $1: $(head -c 200 <<<"$out")"; fails=$((fails+1)); fi
}

echo; echo "── negative checks (as $RO_USER)"
expect_fail "INSERT into the lab database"   497 "INSERT INTO $LAB_DB.write_probe VALUES (now(), 'mcp')"
expect_fail "INSERT into Langfuse scores"    497 "INSERT INTO default.scores (id, project_id) VALUES ('x', 'x')"
expect_fail "CREATE TABLE"                   497 "CREATE TABLE default.mcp_probe (x UInt8) ENGINE=Memory"
expect_fail "SELECT input (prompt bodies)"   497 "SELECT input FROM default.events_full LIMIT 1"
expect_fail "SELECT * (includes input)"      497 "SELECT * FROM default.events_full LIMIT 1"
expect_fail "another database"               497 "SELECT * FROM $LAB_DB.write_probe"
expect_fail "raise max_execution_time"       164 "SELECT 1 SETTINGS max_execution_time = 600"
expect_fail "more than 10000 result rows"    396 "SELECT number FROM numbers(20000)"

echo; echo "── positive controls"
expect_ok "INSERT as admin (same statement)" ch_admin "INSERT INTO $LAB_DB.write_probe VALUES (now(), 'admin'); SELECT count() FROM $LAB_DB.write_probe"
expect_ok "SELECT input as admin"            ch_admin "SELECT count() FROM default.events_full WHERE input != ''"
expect_ok "allowed columns as $RO_USER"      ch_ro    "SELECT count(), uniqExact(trace_id) FROM default.events_full"
expect_ok "input_length as $RO_USER"         ch_ro    "SELECT max(input_length) FROM default.events_full"

echo
if (( fails )); then echo "✗ $fails check(s) failed"; exit 1; fi
echo "✓ all checks passed"
