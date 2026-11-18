#!/usr/bin/env bash
# 09-read-audit.sh — read-access audit logs on Langfuse 4.82.0 (self-hosted, Enterprise).
#
# Runs Langfuse $LF09_VERSION (default 4.82.0, the release that completes read-access logging, 2026-11-17)
# with the EE overlay and this lab's `read-audit` overlay, in its own compose project langfuse-hols-v4audit
# on fresh volumes (a 4.82 schema cannot go back to the stack's 4.56.0). The version is set in the shell
# only (`LANGFUSE_VERSION`, which wins over _base/v4/versions.env); _base/.env is never edited.
# Test 05 (v4.75.0, 2026-11-04) is left as it was.
#
# Steps, in the order the README runs them; the UI parts (Access Logging switch, API key presets, UI
# reads, the viewer and its export) are done in a browser between them:
#   up <org|enforced|disabled> [proxy-count]   (re)create the project in that access-events mode
#   seed                         30 tagged traces with sessions, 3 scores, a dataset + one experiment run
#   api <pass>                   public API + MCP reads with every key in .09-keys.env (and a bad key)
#   ip                           X-Forwarded-For with LANGFUSE_TRUSTED_PROXY_COUNT unset and =1
#   failclosed                   rename the Postgres staging table, read (API + UI), rename back, read
#   report [since UTC]           ClickHouse audit_logs grouped; staging backlog; table TTL; sample rows
#   down                         remove the project and its volumes
# .09-keys.env (git-ignored) holds the UI-made keys as NAME=pk:sk lines (FULL is the init key).
# Output: results/09-read-audit.txt (appended per step), results/09-actions.tsv.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export LANGFUSE_VERSION="${LF09_VERSION:-4.82.0}"
AP=langfuse-hols-v4audit
ENVF="${LF_ENV_FILE:-$BASE_DIR/.env}"
OUT="$RESULTS/09-read-audit.txt"
ACTS="$RESULTS/09-actions.tsv"
KEYS="$HERE/.09-keys.env"
STATE="$RESULTS/09-state.env"
H="$LANGFUSE_HOST"
PROJ="${LANGFUSE_INIT_PROJECT_ID:?}"
: "${LANGFUSE_EE_LICENSE_KEY:?missing in _base/.env}"
JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT
exec > >(tee -a "$OUT") 2>&1

ac() { LF_TRACK=v4 docker compose -p "$AP" --env-file "$TRACK_DIR/versions.env" --env-file "$ENVF" \
         -f "$BASE_DIR/docker-compose.yml" -f "$BASE_DIR/docker-compose.ee.yml" -f "$HERE/docker-compose.read-audit.yml" "$@"; }
ach() { docker exec -i "$AP-clickhouse-1" clickhouse-client -u "${CLICKHOUSE_USER:-clickhouse}" --password "${CLICKHOUSE_PASSWORD:-clickhouse}" -q "$1"; }
apg() { docker exec -i "$AP-postgres-1" psql -U "${POSTGRES_USER:-postgres}" -P pager=off "$@"; }
now() { date -u '+%Y-%m-%d %H:%M:%S'; }

act() {   # act <pass> <key name> <label> <METHOD> <path> <auth> [body] [extra curl args...]
  local pass="$1" kn="$2" label="$3" m="$4" path="$5" auth="$6" body="${7:-}"; shift 7 || shift $#
  local -a a=()
  case "$auth" in session) a=(-b "$JAR");; none) ;; *) a=(-u "$auth");; esac
  local resp code; resp="$(mktemp)"
  code=$(curl -s -o "$resp" -w '%{http_code}' -X "$m" "${a[@]}" -H 'Content-Type: application/json' \
         -H 'Accept: application/json, text/event-stream' ${body:+--data "$body"} "$@" "$H$path")
  LAST="$(cat "$resp")"; rm -f "$resp"; LASTCODE="$code"
  if [[ "$path" == /api/public/mcp* ]]; then   # JSON-RPC answers 200 either way; mark tool errors
    local j; j="$(sed -n 's/^data: //p' <<<"$LAST")"; [[ -n "$j" ]] || j="$LAST"
    if jq -e '.error' >/dev/null 2>&1 <<<"$j"; then code="$code/rpc-error"
    elif jq -e '.result.isError == true' >/dev/null 2>&1 <<<"$j"; then code="$code/tool-error"
    else code="$code/ok"; fi
  fi
  printf '%s\t%s\t%s\t%s\t%s %s\t%s\n' "$(date -u '+%H:%M:%S')" "$pass" "$kn" "$label" "$m" "${path%%\?*}" "$code" >> "$ACTS"
}

login() {
  rm -f "$JAR"
  local csrf
  csrf=$(curl -s -c "$JAR" -b "$JAR" "$H/api/auth/csrf" | jq -r .csrfToken)
  curl -s -o /dev/null -c "$JAR" -b "$JAR" -X POST "$H/api/auth/callback/credentials" \
    --data-urlencode "email=$LANGFUSE_INIT_USER_EMAIL" --data-urlencode "password=$LANGFUSE_INIT_USER_PASSWORD" \
    --data-urlencode "csrfToken=$csrf" --data-urlencode "callbackUrl=$H" --data-urlencode "json=true"
}
trpc_get() {   # trpc_get <pass> <label> <procedure> <json input>
  local enc; enc=$(jq -rn --arg j "{\"0\":{\"json\":$4}}" '$j|@uri')
  act "$1" session "$2" GET "/api/trpc/$3?batch=1&input=$enc" session
}

wait_up() {
  local i
  for i in $(seq 1 120); do
    curl -fsS -o /dev/null "$H/api/public/health" 2>/dev/null && curl -fsS -o /dev/null http://localhost:3030/api/health 2>/dev/null && return 0
    sleep 3
  done
  echo "✗ not healthy after 360 s"; return 1
}

step_up() {   # up <mode> [proxy count]
  export LANGFUSE_AUDIT_LOG_ACCESS_EVENTS="${1:-}" LANGFUSE_TRUSTED_PROXY_COUNT="${2:-}"
  [[ "$LANGFUSE_AUDIT_LOG_ACCESS_EVENTS" == org ]] && LANGFUSE_AUDIT_LOG_ACCESS_EVENTS=""
  echo "== 09 up — $(now) UTC, Langfuse $LANGFUSE_VERSION + EE, project $AP, access events '${LANGFUSE_AUDIT_LOG_ACCESS_EVENTS:-org (default)}', trusted proxies '${LANGFUSE_TRUSTED_PROXY_COUNT:-0 (default)}'"
  lf_compose -- stop >/dev/null 2>&1 || true   # one Langfuse on :3000 at a time
  ac up -d >/dev/null 2>&1
  wait_up
  echo "  health: $(curl -fsS "$H/api/public/health")"
  for v in LANGFUSE_AUDIT_LOG_ACCESS_EVENTS LANGFUSE_AUDIT_LOG_STAGING_ENABLED LANGFUSE_TRUSTED_PROXY_COUNT; do
    echo "  web $v='$(docker exec "$AP-langfuse-web-1" printenv "$v" || true)'"
  done
  echo "  worker relay log: $(docker logs "$AP-langfuse-worker-1" 2>&1 | grep -iE 'audit.?log.?relay|AuditLogRelay' | tail -1 | cut -c1-200)"
}

step_seed() {
  echo "== 09 seed — $(now) UTC"
  "$PY" "$HERE/loadgen.py" --run-id audit-09 --rpm 600 --seconds 3 --prompt-bytes 300 --output-bytes 100 >/dev/null
  local t="" i
  for i in $(seq 1 40); do
    t=$(ach "SELECT trace_id FROM events_full WHERE has(tags,'audit-09') ORDER BY start_time LIMIT 1"); [[ -n "$t" ]] && break; sleep 3
  done
  local o s
  o=$(ach "SELECT span_id FROM events_full WHERE trace_id = '$t' AND parent_span_id = '' LIMIT 1")
  [[ -n "$o" ]] || o=$(ach "SELECT span_id FROM events_full WHERE trace_id = '$t' LIMIT 1")
  s=$(ach "SELECT session_id FROM events_full WHERE trace_id = '$t' AND session_id != '' LIMIT 1")
  local tr; for tr in $(ach "SELECT DISTINCT trace_id FROM events_full WHERE has(tags,'audit-09') LIMIT 3"); do
    curl -s -o /dev/null -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" -H 'Content-Type: application/json' \
      -X POST "$H/api/public/scores" --data "{\"traceId\":\"$tr\",\"name\":\"audit-quality\",\"value\":0.9}"
  done
  "$PY" "$HERE/09b-seed-experiment.py" audit-run
  printf 'T=%s\nO=%s\nS=%s\n' "$t" "$o" "$s" > "$STATE"
  echo "  traces: $(ach "SELECT uniqExact(trace_id) FROM events_full WHERE has(tags,'audit-09')"), trace $t, observation $o, session $s"
  echo "  dataset items: $(curl -s -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" "$H/api/public/dataset-items?datasetName=audit-ds" | jq '.data | length')"
}

reads() {   # reads <pass> <key name> <pk:sk>
  local p="$1" kn="$2" k="$3" from to
  . "$STATE"
  from=$(date -u -v-1d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '-1 day' '+%Y-%m-%dT%H:%M:%SZ')
  to=$(date -u -v+1d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')
  act "$p" "$kn" api.obs.v2      GET "/api/public/v2/observations?traceId=$T&fields=core,basic,io&limit=50" "$k"
  act "$p" "$kn" api.scores.v3   GET "/api/public/v3/scores?limit=10" "$k"
  act "$p" "$kn" api.experiments GET "/api/public/experiments?limit=10&fromStartTime=$from" "$k"
  act "$p" "$kn" api.exp.items   GET "/api/public/experiment-items?limit=10&fromStartTime=$from" "$k"
  act "$p" "$kn" api.trace.v1    GET "/api/public/traces/$T" "$k"
  act "$p" "$kn" api.obs.v1      GET "/api/public/observations?traceId=$T" "$k"
  act "$p" "$kn" api.prompts     GET "/api/public/v2/prompts" "$k"
  act "$p" "$kn" api.datasets    GET "/api/public/v2/datasets" "$k"
  act "$p" "$kn" api.ds.items    GET "/api/public/dataset-items?datasetName=audit-ds" "$k"
  local q; q=$(jq -rn --arg f "$from" --arg t "$to" '{view:"observations",metrics:[{measure:"count",aggregation:"count"}],dimensions:[],filters:[],fromTimestamp:$f,toTimestamp:$t}|tostring|@uri')
  act "$p" "$kn" api.metrics.v2  GET "/api/public/v2/metrics?query=$q" "$k"
  # MCP (streamable HTTP, JSON-RPC)
  local w; w="\"fromStartTime\":\"$from\",\"toStartTime\":\"$(date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')\""   # MCP reads need a window <= 14 days
  act "$p" "$kn" mcp.getObservation  POST /api/public/mcp "$k" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"getObservation\",\"arguments\":{\"observationId\":\"$O\",\"traceId\":\"$T\",$w}}}"
  MCP_HEAD="$(head -c 160 <<<"$LAST" | tr '\n' ' ')"
  act "$p" "$kn" mcp.listObservations POST /api/public/mcp "$k" "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"listObservations\",\"arguments\":{\"traceId\":\"$T\",$w,\"limit\":10}}}"
  act "$p" "$kn" mcp.listScores      POST /api/public/mcp "$k" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"listScores","arguments":{"limit":10}}}'
  act "$p" "$kn" mcp.listExperiments POST /api/public/mcp "$k" "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"listExperiments\",\"arguments\":{$w,\"limit\":10}}}"
}

step_api() {   # api <pass>
  local pass="${1:?pass label}" since; since=$(now)
  echo "== 09 api $pass — $since UTC"
  local -a names=(FULL) keys=("$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY")   # bash 3.2: no associative arrays
  if [[ -f "$KEYS" ]]; then
    while IFS='=' read -r n v; do [[ -n "$n" && "$n" != \#* ]] && { names+=("$n"); keys+=("$v"); }; done < "$KEYS"
  fi
  local i; for i in "${!names[@]}"; do reads "$pass" "${names[$i]}" "${keys[$i]}"; done
  act "$pass" BADKEY api.obs.v2 GET "/api/public/v2/observations?limit=1" "pk-lf-nope:sk-lf-nope"
  echo "  first MCP answer (last key): $MCP_HEAD"
  echo "  HTTP per key (label: FULL ${names[*]:1}):"
  awk -F'\t' -v p="$pass" '$2 == p {c[$4] = c[$4] " " $3 "=" $6} END {for (l in c) printf "    %-20s%s\n", l, c[l]}' "$ACTS" | sort
  sleep 25   # relay interval 10 s
  report_since "$since"
}

report_since() {
  local since="$1"
  echo "  ClickHouse access events since $since (surface, route, resource, action, outcome, reason, actor, key note/user, events, rows):"
  local notes; notes="$(mktemp)"
  docker exec -i "$AP-postgres-1" psql -U "${POSTGRES_USER:-postgres}" -tAF$'\t' -c "SELECT id, coalesce(note, public_key) FROM api_keys" > "$notes"
  ach "SELECT surface, route, resource_type, action, outcome, outcome_reason, actor_type, if(api_key_id != '', api_key_id, actor_email) AS who, count(), sum(result_count)
       FROM audit_logs WHERE event_kind = 'access' AND timestamp >= '$since' GROUP BY ALL ORDER BY surface, route, who FORMAT TSV" |
    awk -F'\t' 'NR == FNR {m[$1] = $2; next}
      {w = ($8 in m) ? m[$8] : $8; printf "    %-10s %-44s %-11s %-4s %-7s %-12s %-7s %-22s %3s %5s\n", $1, $2, $3, $4, $5, $6, $7, w, $9, $10}' "$notes" -
  rm -f "$notes"
  echo "  change events since $since: $(ach "SELECT count() FROM audit_logs WHERE event_kind = 'change' AND timestamp >= '$since'")"
  echo "  staging backlog (Postgres audit_log_staging rows): $(docker exec -i "$AP-postgres-1" psql -U "${POSTGRES_USER:-postgres}" -tAc 'SELECT count(*) FROM audit_log_staging')"
}

step_uiapi() {   # the UI's own HTTP routes and a batch export, with the init user's session cookie
  . "$STATE"
  local since; since=$(now)
  echo "== 09 uiapi — $since UTC (UI session of the init user)"
  login
  local st; st=$(ach "SELECT formatDateTime(start_time, '%Y-%m-%dT%H:%i:%S.%fZ') FROM events_full WHERE span_id = '$O' LIMIT 1" | sed 's/\(\.[0-9]\{3\}\)[0-9]*Z/\1Z/')
  act uiapi session ui.trace.download GET "/api/traces/$T/download?projectId=$PROJ" session
  echo "  trace download → $LASTCODE, $(wc -c <<<"$LAST" | tr -d ' ') bytes, observations in file: $(jq '.observations | length' 2>/dev/null <<<"$LAST" || echo '?')"
  act uiapi session ui.obs.io.input GET "/api/traces/$T/observations/$O/io/input?projectId=$PROJ&startTime=$st" session
  echo "  observation input stream → $LASTCODE, $(wc -c <<<"$LAST" | tr -d ' ') bytes"
  act uiapi session ui.batchExport POST "/api/trpc/batchExport.create?batch=1" session \
    "{\"0\":{\"json\":{\"projectId\":\"$PROJ\",\"name\":\"audit-09\",\"format\":\"CSV\",\"query\":{\"tableName\":\"traces\",\"filter\":[],\"orderBy\":{\"column\":\"timestamp\",\"order\":\"DESC\"}}}}}"
  echo "  batch export create → $LASTCODE, $(head -c 160 <<<"$LAST")"
  sleep 25
  report_since "$since"
}

step_denied() {   # a signed-up user with no membership reads the project's trace in the UI (tRPC)
  . "$STATE"
  local since em pw csrf; since=$(now)
  em="outsider-$(date +%s)@example.com"; pw="$(openssl rand -hex 12)Aa1!"   # throwaway lab user (password rules: mixed case, digit, symbol), password not kept
  echo "== 09 denied — $since UTC (new user $em, no org or project membership)"
  curl -s -o /dev/null -w '  sign-up → %{http_code}\n' -H 'Content-Type: application/json' -X POST "$H/api/auth/signup" \
    --data "{\"name\":\"Outsider 09\",\"email\":\"$em\",\"password\":\"$pw\"}"
  rm -f "$JAR"; csrf=$(curl -s -c "$JAR" -b "$JAR" "$H/api/auth/csrf" | jq -r .csrfToken)
  curl -s -o /dev/null -c "$JAR" -b "$JAR" -X POST "$H/api/auth/callback/credentials" --data-urlencode "email=$em" \
    --data-urlencode "password=$pw" --data-urlencode "csrfToken=$csrf" --data-urlencode "callbackUrl=$H" --data-urlencode "json=true"
  echo "  session: $(curl -s -b "$JAR" "$H/api/auth/session" | jq -r '.user.email // "none"')"
  trpc_get denied ui.trace.detail events.byTraceId "{\"projectId\":\"$PROJ\",\"traceId\":\"$T\"}"
  echo "  UI trace detail as outsider → $LASTCODE, $(head -c 160 <<<"$LAST")"
  act denied session ui.trace.download GET "/api/traces/$T/download?projectId=$PROJ" session
  echo "  trace download as outsider → $LASTCODE"
  sleep 25
  report_since "$since"
}

step_ip() {
  . "$STATE"
  local c since
  for c in "" 1; do
    step_up enforced "$c"
    since=$(now)
    act ip "proxy=${c:-0}" api.obs.v2.xff GET "/api/public/v2/observations?traceId=$T&limit=5" "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" "" -H 'X-Forwarded-For: 203.0.113.7' -H 'User-Agent: audit-09-ip'
    sleep 25
    echo "  proxy count ${c:-unset}: $(ach "SELECT ip, user_agent, request_id FROM audit_logs WHERE event_kind='access' AND user_agent = 'audit-09-ip' AND timestamp >= '$since' FORMAT TSV")"
  done
  step_up enforced
}

step_failclosed() {
  . "$STATE"
  local since; since=$(now)
  echo "== 09 failclosed — $since UTC"
  login
  apg -c "ALTER TABLE audit_log_staging RENAME TO audit_log_staging_off" >/dev/null
  act failclosed FULL api.obs.v2 GET "/api/public/v2/observations?traceId=$T&limit=5" "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY"
  echo "  staging table renamed: public API v2 observations → $LASTCODE, body $(head -c 160 <<<"$LAST")"
  trpc_get failclosed ui.trace.detail events.byTraceId "{\"projectId\":\"$PROJ\",\"traceId\":\"$T\"}"
  echo "  staging table renamed: UI trace detail (tRPC events.byTraceId) → $LASTCODE, body $(head -c 160 <<<"$LAST")"
  act failclosed FULL api.prompts GET "/api/public/v2/prompts" "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY"
  echo "  staging table renamed: prompts list (not audited) → $LASTCODE"
  apg -c "ALTER TABLE audit_log_staging_off RENAME TO audit_log_staging" >/dev/null
  act failclosed FULL api.obs.v2 GET "/api/public/v2/observations?traceId=$T&limit=5" "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY"
  echo "  table back: public API v2 observations → $LASTCODE"
  echo "  web log lines about the failed write (first 3):"
  docker logs --since 3m "$AP-langfuse-web-1" 2>&1 | grep -iE "audit_log_staging|access event|stageAccess" | cut -c1-260 | head -3 | sed 's/^/    /' || true
  sleep 25
  report_since "$since"
}

step_report() {
  local since="${1:-1970-01-01 00:00:00}"
  echo "== 09 report — $(now) UTC, since $since"
  echo "  org setting: $(docker exec -i "$AP-postgres-1" psql -U "${POSTGRES_USER:-postgres}" -tAc "SELECT id || ' access_audit_log_enabled=' || access_audit_log_enabled FROM organizations")"
  echo "  all access events by surface and route (outcome, events, rows):"
  ach "SELECT surface, route, outcome, count(), sum(result_count) FROM audit_logs WHERE event_kind='access' AND timestamp >= '$since' GROUP BY ALL ORDER BY surface, route FORMAT TSV" | sed 's/^/    /'
  echo "  change events by resource and action:"
  ach "SELECT resource_type, action, actor_type, count() FROM audit_logs WHERE event_kind='change' AND timestamp >= '$since' GROUP BY ALL ORDER BY 1, 2 FORMAT TSV" | sed 's/^/    /'
  echo "  table engine, sort key and TTL:"
  ach "SELECT engine_full FROM system.tables WHERE database = currentDatabase() AND name = 'audit_logs'" | sed 's/^/    /'
  echo "  one access event per surface (all fields but before/after):"
  ach "SELECT * EXCEPT (before, after) FROM audit_logs WHERE event_kind='access' AND timestamp >= '$since' ORDER BY timestamp DESC LIMIT 1 BY surface FORMAT Vertical" | cut -c1-240 | sed -E 's/^(api_key_id: +)([a-z0-9]{9})[a-z0-9]+/\1\2… (key record id, shortened)/; s/^/    /'
  echo "  staging backlog: $(docker exec -i "$AP-postgres-1" psql -U "${POSTGRES_USER:-postgres}" -tAc 'SELECT count(*) FROM audit_log_staging')"
}

case "${1:-}" in
  up) step_up "${2:-}" "${3:-}";;
  seed) step_seed;;
  api) step_api "${2:-}";;
  uiapi) step_uiapi;;
  denied) step_denied;;
  ip) step_ip;;
  failclosed) step_failclosed;;
  report) step_report "${2:-}";;
  down) ac down -v >/dev/null 2>&1; echo "== 09 down — $(now) UTC: $AP removed with its volumes";;
  *) sed -n '2,24p' "$0"; exit 1;;
esac
