#!/usr/bin/env bash
# 05-audit-log.sh — which actions land in the audit log on the latest Langfuse v4 (Enterprise)?
#
# Runs Langfuse VERSION (default 4.75.0, the latest v4 release on 2026-11-04) with the EE overlay, set ONLY
# through a LANGFUSE_VERSION line appended to _base/.env, which is removed again at the end. The run uses
# its own compose project, langfuse-hols-v4audit, with fresh volumes: a 4.75 schema migration cannot be
# rolled back to 4.56.0, so the stack's own volumes are never touched. The v4 stack is stopped meanwhile
# (one Langfuse stack at a time) and started again in OSS mode afterwards.
#
# Two passes over the same actions:
#   default    LANGFUSE_AUDIT_LOG_ACCESS_EVENTS unset ("org": reads only for orgs that opted in; none did)
#   enforced   LANGFUSE_AUDIT_LOG_ACCESS_EVENTS=enforced (overlay `audit`): reads for every org
# Actions: CRUD on prompts, projects, project API keys, org members (SCIM user + membership) over the public
# and admin APIs; reads: trace detail in the UI (tRPC events.byTraceId, with a session from the credentials
# login), GET /api/public/traces/{id}, trace and session lists, the v2 observations list, a batch-export
# request. Then: what is in Postgres `audit_logs` / `audit_log_staging` and in ClickHouse `audit_logs`.
#   Usage: ./05-audit-log.sh [version]        Writes results/05-audit-log.txt
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
VERSION="${1:-4.75.0}"
AP=langfuse-hols-v4audit
OUT="$RESULTS/05-audit-log.txt"
ACTS="$RESULTS/05-actions.tsv"
exec > >(tee "$OUT") 2>&1
ENVF="${LF_ENV_FILE:-$BASE_DIR/.env}"
: "${ADMIN_API_KEY:?missing in _base/.env}" "${LANGFUSE_EE_LICENSE_KEY:?missing in _base/.env}"
H="$LANGFUSE_HOST"
PK="$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY"
ORG="${LANGFUSE_INIT_ORG_ID:?}"; PROJ="${LANGFUSE_INIT_PROJECT_ID:?}"
JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT

ac() { LF_TRACK=v4 docker compose -p "$AP" --env-file "$TRACK_DIR/versions.env" --env-file "$ENVF" \
         -f "$BASE_DIR/docker-compose.yml" -f "$BASE_DIR/docker-compose.ee.yml" -f "$HERE/docker-compose.audit.yml" "$@"; }
ach() { docker exec -i "$AP-clickhouse-1" clickhouse-client -u "${CLICKHOUSE_USER:-clickhouse}" --password "${CLICKHOUSE_PASSWORD:-clickhouse}" -q "$1"; }
apg() { docker exec -i "$AP-postgres-1" psql -U "${POSTGRES_USER:-postgres}" -P pager=off -c "$1"; }
restore() {
  sed -i.bak '/^LANGFUSE_VERSION=.*# 05-audit-log override$/d' "$ENVF" && rm -f "$ENVF.bak"
  ac down -v >/dev/null 2>&1 || true
  "$BASE_DIR/bin/up.sh" v4 >/dev/null
  echo "-- restored: _base/.env without the override, $AP removed with its volumes, v4 stack up in OSS mode"
}

echo "== 05 audit log — $(date -u '+%Y-%m-%dT%H:%M:%SZ'), Langfuse $VERSION + EE overlay, project $AP (fresh volumes)"
lf_compose -- stop >/dev/null 2>&1
grep -q '05-audit-log override' "$ENVF" || echo "LANGFUSE_VERSION=$VERSION   # 05-audit-log override" >> "$ENVF"
trap 'restore; rm -f "$JAR"' EXIT

up_pass() {   # up_pass <access-events mode or empty>
  export LANGFUSE_AUDIT_LOG_ACCESS_EVENTS="$1"
  ac up -d >/dev/null 2>&1
  for _ in $(seq 1 90); do curl -fsS -o /dev/null "$H/api/public/health" 2>/dev/null && break; sleep 4; done
  echo "  health: $(curl -fsS "$H/api/public/health")  web env LANGFUSE_AUDIT_LOG_ACCESS_EVENTS='$(docker exec "$AP-langfuse-web-1" printenv LANGFUSE_AUDIT_LOG_ACCESS_EVENTS || true)'"
  sleep 10
}

act() {   # act <phase> <label> <METHOD> <path> <auth: pk|org|admin|session> [json body]
  local phase="$1" label="$2" m="$3" path="$4" auth="$5" body="${6:-}" code
  local -a a=()
  case "$auth" in
    pk) a=(-u "$PK");; org) a=(-u "$ORGK");; admin) a=(-H "Authorization: Bearer $ADMIN_API_KEY");;
    session) a=(-b "$JAR");;
  esac
  local resp; resp="$(mktemp)"
  code=$(curl -s -o "$resp" -w '%{http_code}' -X "$m" "${a[@]}" -H 'Content-Type: application/json' \
         ${body:+--data "$body"} "$H$path")
  printf '%s\t%s\t%s\t%s %s\t%s\n' "$(date -u '+%H:%M:%S')" "$phase" "$label" "$m" "${path%%\?*}" "$code" >> "$ACTS"
  LAST="$(cat "$resp")"; rm -f "$resp"
}

login() {
  rm -f "$JAR"
  local csrf
  csrf=$(curl -s -c "$JAR" -b "$JAR" "$H/api/auth/csrf" | jq -r .csrfToken)
  curl -s -o /dev/null -c "$JAR" -b "$JAR" -X POST "$H/api/auth/callback/credentials" \
    --data-urlencode "email=$LANGFUSE_INIT_USER_EMAIL" --data-urlencode "password=$LANGFUSE_INIT_USER_PASSWORD" \
    --data-urlencode "csrfToken=$csrf" --data-urlencode "callbackUrl=$H" --data-urlencode "json=true"
  echo "  UI session for the init user: $(curl -s -b "$JAR" "$H/api/auth/session" | jq -r '.user.email // "none"')"
}

trpc_get() {   # trpc_get <phase> <label> <procedure> <json input>
  local enc; enc=$(jq -rn --arg j "{\"0\":{\"json\":$4}}" '$j|@uri')
  act "$1" "$2" GET "/api/trpc/$3?batch=1&input=$enc" session
}
trpc_post() {
  act "$1" "$2" POST "/api/trpc/$3?batch=1" session "{\"0\":{\"json\":$4}}"
}

actions() {   # actions <phase>
  local ph="$1" t s
  # data to read
  "$PY" "$HERE/loadgen.py" --run-id "audit-$ph" --rpm 600 --seconds 3 --prompt-bytes 300 --output-bytes 100 >/dev/null
  for _ in $(seq 1 30); do
    t=$(ach "SELECT trace_id FROM events_full WHERE has(tags,'audit-$ph') LIMIT 1"); [[ -n "$t" ]] && break; sleep 2
  done
  s=$(ach "SELECT session_id FROM events_full WHERE has(tags,'audit-$ph') AND session_id != '' LIMIT 1")
  # prompts (project key)
  act "$ph" prompt.create POST /api/public/v2/prompts pk "{\"name\":\"audit-$ph\",\"type\":\"text\",\"prompt\":\"hi {{x}}\",\"labels\":[]}"
  act "$ph" prompt.labels PATCH "/api/public/v2/prompts/audit-$ph/versions/1" pk '{"newLabels":["production"]}'
  act "$ph" prompt.get GET "/api/public/v2/prompts/audit-$ph" pk
  act "$ph" prompt.delete DELETE "/api/public/v2/prompts/audit-$ph" pk
  # org API key (admin API), then projects, project API keys, members (org key)
  act "$ph" orgkey.create POST "/api/admin/organizations/$ORG/apiKeys" admin '{"note":"05-audit-log"}'
  ORGK="$(jq -r '.publicKey + ":" + .secretKey' <<<"$LAST")"
  act "$ph" project.create POST /api/public/projects org "{\"name\":\"audit-$ph\",\"retention\":0}"
  local p; p=$(jq -r '.id // empty' <<<"$LAST")
  act "$ph" project.update PUT "/api/public/projects/$p" org "{\"name\":\"audit-$ph-renamed\",\"retention\":0}"
  act "$ph" apikey.create POST "/api/public/projects/$p/apiKeys" org '{"note":"05"}'
  local k; k=$(jq -r '.id // empty' <<<"$LAST")
  act "$ph" apikey.list GET "/api/public/projects/$p/apiKeys" org
  act "$ph" apikey.delete DELETE "/api/public/projects/$p/apiKeys/$k" org
  act "$ph" scim.user.create POST /api/public/scim/Users org "{\"userName\":\"auditor-$ph@example.com\",\"name\":{\"formatted\":\"Auditor $ph\"},\"emails\":[{\"primary\":true,\"value\":\"auditor-$ph@example.com\"}],\"active\":true}"
  local u; u=$(jq -r '.id // empty' <<<"$LAST")
  act "$ph" member.role PUT /api/public/organizations/memberships org "{\"userId\":\"$u\",\"role\":\"VIEWER\"}"
  act "$ph" member.project PUT "/api/public/projects/$p/memberships" org "{\"userId\":\"$u\",\"role\":\"MEMBER\"}"
  act "$ph" member.list GET /api/public/organizations/memberships org
  act "$ph" member.remove DELETE /api/public/organizations/memberships org "{\"userId\":\"$u\"}"
  act "$ph" project.delete DELETE "/api/public/projects/$p" org
  # reads (project key)
  act "$ph" read.trace GET "/api/public/traces/$t" pk
  act "$ph" read.traces.list GET "/api/public/traces?limit=5" pk
  act "$ph" read.obs.v2.list GET "/api/public/v2/observations?traceId=$t&limit=50" pk
  act "$ph" read.sessions.list GET "/api/public/sessions?limit=5" pk
  act "$ph" read.session GET "/api/public/sessions/$s" pk
  # UI (session cookie)
  login
  trpc_get "$ph" ui.trace.detail events.byTraceId "{\"projectId\":\"$PROJ\",\"traceId\":\"$t\"}"
  echo "  ui.trace.detail response head: $(head -c 160 <<<"$LAST")"
  trpc_post "$ph" ui.batchExport batchExport.create "{\"projectId\":\"$PROJ\",\"name\":\"audit-$ph\",\"format\":\"CSV\",\"query\":{\"tableName\":\"traces\",\"filter\":[],\"orderBy\":{\"column\":\"timestamp\",\"order\":\"DESC\"}}}"
  echo "  ui.batchExport response head: $(head -c 200 <<<"$LAST")"
  # admin replay of one raw OTLP file with its full key (on 4.56.0 it answers "Unsupported replay type: otel")
  local key; key=$(ach "SELECT blob_storage_file_path FROM events_full WHERE trace_id = '$t' LIMIT 1")
  act "$ph" admin.replay POST /api/admin/ingestion-replay admin "{\"keys\":[\"$key\"]}"
  echo "  admin.replay of $key: $LAST"
  sleep 60   # the worker relays audit_log_staging to ClickHouse every 10 s
  echo "  web log lines about audit / access events (first 5):"
  docker logs --since 5m "$AP-langfuse-web-1" 2>&1 | grep -iE "audit|access event" | cut -c1-300 | head -5 | sed 's/^/    /' || true
}

report() {   # report <phase> <since UTC>
  echo "  actions sent (label, method path, HTTP):"
  awk -F'\t' -v ph="$1" '$2 == ph {printf "    %-18s %-55s %s\n", $3, $4, $5}' "$ACTS"
  echo "  Postgres audit_logs since $2 (resource_type, action, by, count):"
  apg "SELECT resource_type, action, CASE WHEN user_id IS NOT NULL THEN 'user' WHEN api_key_id IS NOT NULL THEN 'api_key' ELSE 'other' END AS actor, count(*) FROM audit_logs WHERE created_at >= '$2' GROUP BY 1,2,3 ORDER BY 1,2" | sed 's/^/    /'
  echo "  Postgres audit_log_staging since $2 (kind, resourceType, action, count; still waiting for the relay):"
  apg "SELECT payload->>'kind' kind, payload->>'resourceType' rt, payload->>'action' act, count(*) FROM audit_log_staging WHERE created_at >= '$2' GROUP BY 1,2,3 ORDER BY 1,2,3" | sed 's/^/    /'
  echo "  ClickHouse audit_logs since $2 (kind, actor, resource_type, action, surface, route, rows, count):"
  ach "SELECT event_kind, actor_type, resource_type, action, surface, route, sum(result_count), count() FROM audit_logs FINAL WHERE timestamp >= '$2' GROUP BY ALL ORDER BY event_kind, resource_type, action FORMAT PrettyCompactMonoBlock" | sed 's/^/    /' || true
  echo "  ClickHouse audit_logs total rows: $(ach "SELECT count() FROM audit_logs FINAL" || true); staging rows total: $(docker exec -i "$AP-postgres-1" psql -U "${POSTGRES_USER:-postgres}" -tAc "SELECT count(*) FROM audit_log_staging" || true)"
  echo "  worker log lines about the audit relay (first 5):"
  docker logs --since 10m "$AP-langfuse-worker-1" 2>&1 | grep -iE "audit" | cut -c1-300 | head -5 | sed 's/^/    /' || true
}

: > "$ACTS"
for mode in default enforced; do
  echo "-- pass: $mode"
  up_pass "$([[ $mode == enforced ]] && echo enforced || true)"
  [[ $mode == default ]] && {
    echo "  ClickHouse audit_logs columns: $(ach "SELECT arrayStringConcat(groupArray(name), ', ') FROM system.columns WHERE database = currentDatabase() AND table = 'audit_logs'")"
    echo "  Postgres tables: $(docker exec -i "$AP-postgres-1" psql -U "${POSTGRES_USER:-postgres}" -tAc "SELECT string_agg(table_name, ', ') FROM information_schema.tables WHERE table_name LIKE 'audit_log%'")"
  }
  since=$(date -u '+%Y-%m-%d %H:%M:%S')
  actions "$mode"
  report "$mode" "$since"
done
