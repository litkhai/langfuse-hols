# lib.sh — sourced by the numbered scripts of labs/v4/langfuse-ch-mv.
#
#   ch "<sql>" [format]     one statement over ClickHouse HTTP (default format TSV); fails on an HTTP error
#   chq <query_id> "<sql>"  the same with a fixed query_id, so its row in system.query_log can be read back
#   chf <file.sql>          every statement of a file, in order (split on lines that end with ";")
#   qlog <query_id>         "duration_ms read_rows read_bytes result_rows" of a finished query (after a log flush)
#
# CH_URL (default http://localhost:8123) and the CLICKHOUSE_USER / CLICKHOUSE_PASSWORD of _base/.env.
# LF_ENV_FILE replaces _base/.env (a worktree has none: point it at the main checkout's file).
# LAB_DB is the only database this lab creates or drops; the Langfuse tables are read, never written.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../../_base/lib/env.sh" v4
load_env "${LF_ENV_FILE:-$BASE_DIR/.env}"
export LANGFUSE_HOST="${NEXTAUTH_URL:-http://localhost:3000}"
export LANGFUSE_PUBLIC_KEY="${LANGFUSE_INIT_PROJECT_PUBLIC_KEY:?missing in _base/.env}"
export LANGFUSE_SECRET_KEY="${LANGFUSE_INIT_PROJECT_SECRET_KEY:?missing in _base/.env}"
export LAB_TAG="lab:langfuse-ch-mv"
export LAB_DB="lab_langfuse_ch_mv"
CH_URL="${CH_URL:-http://localhost:8123}"
RESULTS="$HERE/results"
mkdir -p "$RESULTS"
PY="${PY:-$BASE_DIR/../.venv-v4/bin/python}"
[[ -x "$PY" ]] || PY="$(git -C "$HERE" worktree list --porcelain | awk '/^worktree /{print $2; exit}')/.venv-v4/bin/python"
[[ -x "$PY" ]] || PY=python3

_ch_post() {   # _ch_post <url-query> <sql>
  local out code
  out=$(curl -sS -w '\n%{http_code}' -u "$CLICKHOUSE_USER:$CLICKHOUSE_PASSWORD" \
        "$CH_URL/?$1" --data-binary "$2") || return 1
  code="${out##*$'\n'}"; out="${out%$'\n'*}"; out="${out%$'\n'}"
  if [[ "$code" != 200 ]]; then printf '%s\n' "$out" >&2; return 1; fi
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}
ch()  { _ch_post "default_format=${2:-TSV}" "$1"; }
chq() { _ch_post "default_format=${3:-TSV}&query_id=$1" "$2"; }
chf() {
  local stmt="" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*-- && -z "$stmt" ]] && continue
    stmt+="$line"$'\n'
    if [[ "$line" =~ \;[[:space:]]*$ ]]; then
      ch "$stmt" PrettyCompactMonoBlock || { echo "✗ failed in $1:" >&2; printf '%s' "$stmt" | head -5 >&2; return 1; }
      stmt=""
    fi
  done < "$1"
}
qlog() {
  ch "SYSTEM FLUSH LOGS" >/dev/null
  ch "SELECT query_duration_ms, read_rows, read_bytes, result_rows FROM system.query_log
      WHERE query_id = '$1' AND type = 'QueryFinish' ORDER BY event_time_microseconds DESC LIMIT 1"
}
# view_select <target> <predicate> [source]: the SELECT of view <target>_mv (from system.tables) with its
# created_at condition replaced by <predicate>, reading [source] (default: default.events_full FINAL).
# view_insert <target> <predicate>: INSERT INTO <target> that SELECT. 03 uses it for the backfill
# (created_at < cutoff), 08 to rebuild hours (toStartOfHour(start_time) IN (…)), 05 and 06 to put the same
# views on copies of events_full.
view_select() {
  local t="$1" pred="$2" src="${3:-default.events_full FINAL}" sel
  sel=$(ch "SELECT as_select FROM system.tables WHERE database = '$LAB_DB' AND name = '${t}_mv'" TSVRaw)
  [[ "$sel" =~ \(created_at\ \>=\ toDateTime64\(\'[^\']*\',\ 6\)\) ]] || { echo "✗ ${t}_mv: no created_at condition" >&2; return 1; }
  sel="${sel/"${BASH_REMATCH[0]}"/($pred)}"
  printf '%s' "${sel/FROM default.events_full /FROM $src }"
}
target_columns() {   # target_columns <db> <table>: the columns an INSERT must name (no DEFAULT ones)
  ch "SELECT arrayStringConcat(groupArray(name), ', ') FROM (SELECT name FROM system.columns
      WHERE database = '$1' AND table = '$2' AND default_kind = '' ORDER BY position)"
}
view_insert() {
  local sel; sel=$(view_select "$1" "$2") || return 1
  ch "INSERT INTO $LAB_DB.$1 ($(target_columns "$LAB_DB" "$1")) $sel"
}
pass=0; fail=0
check() {   # check <name> <expected> <actual>
  local shown="$3"; [[ "$3" == *$'\n'* ]] && shown="$(printf '%s\n' "$3" | wc -l | tr -d ' ') rows"
  if [[ "$2" == "$3" ]]; then echo "PASS  $1  ($shown)"; pass=$((pass+1))
  else echo "FAIL  $1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/      /'; fail=$((fail+1)); fi
}
