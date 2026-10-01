#!/usr/bin/env bash
# Parse-check every tracked .sql file with ClickHouse's own formatter.
# Run from anywhere inside the repository:  ./.github/scripts/check_sql.sh
#
# This is a PARSE check only. `clickhouse format` builds the syntax tree and throws it
# away: a typo such as SELEC fails, but a table or column name that does not exist (or
# exists under another name in Langfuse's schema) still passes. Whether the queries return
# what the labs say is what the labs' own runs are for.
#
# The image is the ClickHouse the merged base compose resolves, so this follows the pin
# that #6 sets rather than a version written here. Needs: docker (compose plugin included).
# Needs no secret and no running stack.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

# Same input rule as check_compose.sh: ignore a developer's _base/.env and shell overrides.
unset CLICKHOUSE_VERSION COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES

if ! images=$(docker compose -f _base/docker-compose.yml --env-file /dev/null config --images 2>&1); then
    echo "FAIL: docker compose config --images"
    printf '%s\n' "$images" | sed 's/^/      /'
    exit 1
fi
image=$(printf '%s\n' "$images" | grep 'clickhouse-server' || true)
if [ "$(printf '%s\n' "$image" | grep -c .)" -ne 1 ]; then
    echo "FAIL: expected exactly one clickhouse-server image in _base/docker-compose.yml, got:"
    printf '%s\n' "${image:-<none>}" | sed 's/^/      /'
    exit 1
fi

echo "image: $image"
docker pull --quiet "$image" >/dev/null || { echo "FAIL: docker pull $image"; exit 1; }
echo "version: $(docker run --rm --entrypoint clickhouse "$image" local --version)"

files=$(git ls-files '*.sql')
count=$(printf '%s\n' "$files" | grep -c .)
if [ "$count" -eq 0 ]; then
    # A check that finds nothing to check must not pass: it would stay green after a rename.
    echo "FAIL: git ls-files '*.sql' found no files"
    exit 1
fi

failed=0
echo "--- clickhouse format --multiquery --quiet ($count files)"
while IFS= read -r f; do
    # stdin, not a bind mount: no path or permission differences between laptop and CI.
    # --entrypoint skips the server's entrypoint script; format needs only the binary.
    if out=$(docker run --rm -i --entrypoint clickhouse "$image" format --multiquery --quiet < "$f" 2>&1); then
        echo "    OK    $f"
    else
        echo "    FAIL  $f"
        # First line only, without the "Expected one of: ..." list and the C++ stack trace.
        printf '%s\n' "$out" | head -n 1 \
            | sed -e 's/\. Expected one of:.*$/./' -e 's/, Stack trace (when copying.*$//' \
            | sed 's/^/          /'
        failed=1
    fi
done <<< "$files"

echo
if [ "$failed" -eq 0 ]; then
    echo "OK: all $count .sql files parse (syntax only; names are not validated)"
else
    echo "FAIL: see FAIL lines above"
fi
exit "$failed"
