#!/usr/bin/env bash
# Check that the shared Langfuse stack of one track is up and usable.
#
# Each check prints PASS, FAIL or SKIP. SKIP is not a pass: it means the check
# does not apply to what is running, or a credential for it is missing.
#
#   _base/bin/check.sh <v3|v4>
#   _base/bin/check.sh <v3|v4> --env-file path/to/other.env
#
# Checks: the six containers of langfuse-hols-<track> run (and the four with a healthcheck
# are healthy) · web and worker answer · the version web reports equals the LANGFUSE_VERSION
# compose resolves (versions.env, then the env file, then the shell) · Langfuse's
# ClickHouse migrations finished (not just the server answering) · the SDK keys are
# accepted · the masking sidecar, if running, is healthy. Needs only docker and curl.
# Never prints a key value.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$here/.env"
track=""
usage="usage: _base/bin/check.sh <v3|v4> [--env-file PATH]"

while [ $# -gt 0 ]; do
    case "$1" in
        --env-file) env_file="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        v[0-9]*) track="$1"; shift ;;
        *) echo "unknown argument: $1" >&2; echo "$usage" >&2; exit 2 ;;
    esac
done

if [[ ! "$track" =~ ^v[0-9]+$ || ! -f "$here/$track/versions.env" ]]; then
    echo "$usage" >&2
    exit 2
fi

for tool in docker curl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required" >&2; exit 1; }
done

if [ ! -f "$env_file" ]; then
    echo "no env file at $env_file -- run _base/bin/up.sh $track (it creates _base/.env from .env.example)" >&2
    exit 1
fi

# shellcheck disable=SC1091
. "$here/lib/env.sh" "$track"

# The version compose resolves for the images: the shell wins over the env file, which wins
# over versions.env. Work it out BEFORE load_env, which exports the env file into this shell.
# Each file is read in a subshell with load_env, so quoting and comments behave as below.
file_value() {  # file key -> the key's value in that file (empty if absent)
    ( unset "$2"; load_env "$1"; printf '%s' "${!2:-}" )
}
expected_version="$(file_value "$TRACK_DIR/versions.env" LANGFUSE_VERSION)"
v="$(file_value "$env_file" LANGFUSE_VERSION)"
[ -n "$v" ] && expected_version="$v"
[ -n "${LANGFUSE_VERSION:-}" ] && expected_version="$LANGFUSE_VERSION"

load_env "$env_file"
export LF_ENV_FILE="$env_file"   # lf_compose passes this file (not _base/.env) to compose

HOST="${NEXTAUTH_URL:-http://localhost:3000}"
HOST="${HOST%/}"
WORKER_URL="http://localhost:3030"     # published by docker-compose.yml
CH_URL="http://localhost:8123"         # published by docker-compose.yml
CH_USER="${CLICKHOUSE_USER:-clickhouse}"
CH_PASSWORD="${CLICKHOUSE_PASSWORD:-clickhouse}"
MIGRATIONS_DIR="/app/packages/shared/clickhouse/migrations/unclustered"

failed=0
skipped=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n     %s\n' "$1" "${2:-}"; failed=1; }
skip() { printf 'SKIP  %s\n     %s\n' "$1" "${2:-}"; skipped=$((skipped + 1)); }

# HTTP helper. Sets HTTP_CODE (000 = no answer) and HTTP_BODY.
#   req URL [USER:PASS] [extra curl args...]
# Credentials go to curl on stdin (-K -), not on the command line, so they do not
# show up in `ps` and are never echoed.
req() {
    local url="$1" cred="${2:-}" resp
    shift $(( $# >= 2 ? 2 : $# ))
    if [ -n "$cred" ]; then
        cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"
        resp=$(printf 'user = "%s"\n' "$cred" \
               | curl -s --max-time 20 -K - -w $'\n%{http_code}' "$@" "$url")
    else
        resp=$(curl -s --max-time 20 -w $'\n%{http_code}' "$@" "$url")
    fi
    HTTP_CODE="${resp##*$'\n'}"
    HTTP_BODY="${resp%$'\n'*}"
}

# compose against this track's stack. Overlays are not needed to list containers.
compose() { lf_compose -- "$@"; }

echo "stack: $LF_PROJECT  (env file: $env_file)"
echo

# --- 1. Containers ---------------------------------------------------------
ps_out=$(compose ps -a --format '{{.Service}}|{{.State}}|{{.Health}}' 2>&1)
ps_rc=$?
svc_field() {  # svc field(2=state,3=health) -> value, empty if the service is absent
    printf '%s\n' "$ps_out" | awk -F'|' -v s="$1" -v f="$2" '$1 == s { print $f; exit }'
}

if [ "$ps_rc" -ne 0 ]; then
    fail "containers" "docker compose ps failed: $ps_out"
else
    # name:needs_healthcheck
    for entry in langfuse-web:0 langfuse-worker:0 postgres:1 clickhouse:1 redis:1 minio:1; do
        svc="${entry%%:*}"; hc="${entry##*:}"
        state=$(svc_field "$svc" 2)
        health=$(svc_field "$svc" 3)
        if [ -z "$state" ]; then
            fail "container $svc" "not found -- start the stack with _base/bin/up.sh $TRACK"
        elif [ "$state" != "running" ]; then
            fail "container $svc" "state is '$state', expected 'running'"
        elif [ "$hc" = "1" ] && [ "$health" != "healthy" ]; then
            fail "container $svc" "running but health is '${health:-none}', expected 'healthy'"
        elif [ "$hc" = "1" ]; then
            pass "container $svc running, healthy"
        else
            pass "container $svc running"
        fi
    done
fi

# --- 2. Web / worker -------------------------------------------------------
req "$HOST/api/public/health"
if [ "$HTTP_CODE" = "200" ]; then
    ver=$(printf '%s' "$HTTP_BODY" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    pass "web $HOST/api/public/health -> 200 (Langfuse ${ver:-version not reported})"
    if [ "$ver" = "$expected_version" ]; then
        pass "web version $ver equals LANGFUSE_VERSION ($TRACK pin or override)"
    else
        fail "web version" "health reports '${ver:-none}', LANGFUSE_VERSION resolves to '${expected_version:-none}' -- is the other track (or an older image) answering on $HOST?"
    fi
else
    fail "web $HOST/api/public/health" "HTTP $HTTP_CODE"
fi

req "$WORKER_URL/api/health"
if [ "$HTTP_CODE" = "200" ]; then
    pass "worker $WORKER_URL/api/health -> 200"
else
    fail "worker $WORKER_URL/api/health" "HTTP $HTTP_CODE"
fi

# --- 3. Langfuse's ClickHouse migrations finished --------------------------
# Langfuse runs golang-migrate against ClickHouse. The server answering does not
# mean the schema is there: the latest row of the migration table must be clean
# (dirty = 0) and its version must equal the highest migration the web image ships.
ch_sql() { req "$CH_URL/?default_format=TSV" "$CH_USER:$CH_PASSWORD" --data-binary "$1"; }

ch_sql "SELECT version, dirty FROM default.schema_migrations ORDER BY sequence DESC LIMIT 1"
if [ "$HTTP_CODE" != "200" ]; then
    fail "ClickHouse migrations" "could not read default.schema_migrations (HTTP $HTTP_CODE): $(printf '%s' "$HTTP_BODY" | head -c 200)"
else
    applied=$(printf '%s' "$HTTP_BODY" | awk -F'\t' 'NR==1 {print $1}')
    dirty=$(printf '%s' "$HTTP_BODY" | awk -F'\t' 'NR==1 {print $2}')
    files=$(compose exec -T langfuse-web ls "$MIGRATIONS_DIR" 2>&1)
    files_rc=$?
    shipped=""
    if [ "$files_rc" -eq 0 ]; then
        # 0001_traces.up.sql -> 1 ; the highest number among the *.up.sql files
        shipped=$(printf '%s\n' "$files" | sed -n 's/^\([0-9][0-9]*\)_.*\.up\.sql.*$/\1/p' \
                  | awk '{ if ($1 + 0 > m) m = $1 + 0 } END { if (NR) print m }')
    fi
    if [ -z "$applied" ] || [ -z "$dirty" ]; then
        fail "ClickHouse migrations" "default.schema_migrations is empty -- the web container has not migrated yet"
    elif [ "$files_rc" -ne 0 ] || [ -z "$shipped" ]; then
        fail "ClickHouse migrations" "applied=$applied dirty=$dirty, but cannot list $MIGRATIONS_DIR in langfuse-web: $(printf '%s' "$files" | head -c 200)"
    elif [ "$dirty" != "0" ]; then
        fail "ClickHouse migrations" "latest migration $applied is dirty (a migration failed half-way); shipped=$shipped"
    elif [ "$applied" != "$shipped" ]; then
        fail "ClickHouse migrations" "applied=$applied shipped=$shipped -- still migrating, or the migration stopped"
    else
        pass "ClickHouse migrations finished (applied $applied, shipped $shipped, dirty 0)"
    fi
fi

# --- 4. SDK keys -----------------------------------------------------------
if [ -z "${LANGFUSE_PUBLIC_KEY:-}" ] || [ -z "${LANGFUSE_SECRET_KEY:-}" ]; then
    skip "SDK keys" "LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY are not set in $env_file"
else
    req "$HOST/api/public/projects" "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY"
    case "$HTTP_CODE" in
        200) pass "SDK keys accepted ($HOST/api/public/projects -> 200)" ;;
        401) fail "SDK keys" "HTTP 401 -- LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY do not match a project (check LANGFUSE_INIT_PROJECT_* in $env_file)" ;;
        *)   fail "SDK keys" "HTTP $HTTP_CODE from $HOST/api/public/projects" ;;
    esac
fi

# --- 5. Overlays -----------------------------------------------------------
if [ "$ps_rc" -ne 0 ]; then
    skip "masking sidecar" "container list unavailable"
else
    m_state=$(svc_field masking 2)
    m_health=$(svc_field masking 3)
    if [ "$m_state" != "running" ]; then
        skip "masking sidecar" "not running -- only lab 08 (docker-compose.masking.yml) starts it"
    elif [ "$m_health" = "healthy" ]; then
        pass "masking sidecar running, healthy"
    else
        fail "masking sidecar" "running but health is '${m_health:-none}', expected 'healthy'"
    fi
fi

echo
[ "$skipped" -gt 0 ] && echo "$skipped check(s) skipped -- a skip is not a pass."
if [ "$failed" -ne 0 ]; then
    echo "stack is not ready."
    exit 1
fi
echo "stack is ready."
