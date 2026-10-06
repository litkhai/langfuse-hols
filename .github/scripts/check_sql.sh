#!/usr/bin/env bash
# Parse-check every tracked .sql file with ClickHouse's own formatter, per track.
# Run from anywhere inside the repository:  ./.github/scripts/check_sql.sh
#
# This is a PARSE check only. `clickhouse format` builds the syntax tree and throws it
# away: a typo such as SELEC fails, but a table or column name that does not exist (or
# exists under another name in Langfuse's schema) still passes. Whether the queries return
# what the labs say is what the labs' own runs are for.
#
# Tracks (#33): every _base/<track>/versions.env is one track, and its labs live under
# labs/<track>/. The SQL of a track is parsed with the ClickHouse image that track's merged
# base compose resolves, so this follows the pins in versions.env rather than a version
# written here. A track with no .sql under labs/<track>/ FAILS (a check that finds nothing
# to check must not pass), and so does any tracked .sql that sits outside every track's
# labs/<track>/ directory, so nothing goes unparsed.
#
# Needs: docker (compose plugin included). Needs no secret and no running stack.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

# Same input rule as check_compose.sh: ignore a developer's _base/.env and shell overrides.
# The variables are unset one by one below; versions.env is the only env file passed.
for v in COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES \
         $(grep -ohE '\$\{[A-Za-z_][A-Za-z_0-9]*' _base/docker-compose*.yml | tr -d '${' | sort -u); do
    unset "$v"
done

tracks=()
for f in _base/*/versions.env; do
    [ -f "$f" ] && tracks+=("$(basename "$(dirname "$f")")")
done
if [ "${#tracks[@]}" -eq 0 ]; then
    echo "FAIL: no _base/*/versions.env found -- there is no track to check"
    exit 1
fi
echo "tracks: ${tracks[*]}"

failed=0
pulled=""   # newline-separated images already pulled: each distinct image is pulled once

for track in "${tracks[@]}"; do
    echo
    echo "=== track $track"

    if ! images=$(docker compose --env-file "_base/$track/versions.env" -f _base/docker-compose.yml config --images 2>&1); then
        echo "FAIL: docker compose config --images ($track)"
        printf '%s\n' "$images" | sed 's/^/      /'
        failed=1
        continue
    fi
    image=$(printf '%s\n' "$images" | grep 'clickhouse-server' || true)
    if [ "$(printf '%s\n' "$image" | grep -c .)" -ne 1 ]; then
        echo "FAIL: expected exactly one clickhouse-server image in _base/docker-compose.yml for $track, got:"
        printf '%s\n' "${image:-<none>}" | sed 's/^/      /'
        failed=1
        continue
    fi

    files=$(git ls-files "labs/$track/*.sql")
    count=$(printf '%s\n' "$files" | grep -c .)
    if [ "$count" -eq 0 ]; then
        # A check that finds nothing to check must not pass: it would stay green after a rename.
        echo "FAIL: no .sql under labs/$track/ (git ls-files 'labs/$track/*.sql' found nothing)"
        failed=1
        continue
    fi

    echo "image: $image"
    if ! printf '%s\n' "$pulled" | grep -qxF "$image"; then
        docker pull --quiet "$image" >/dev/null || { echo "FAIL: docker pull $image"; failed=1; continue; }
        pulled="$pulled
$image"
    fi
    echo "version: $(docker run --rm --entrypoint clickhouse "$image" local --version)"

    echo "--- clickhouse format --multiquery --quiet ($count files)"
    track_failed=0
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
            track_failed=1
        fi
    done <<< "$files"
    if [ "$track_failed" -eq 0 ]; then
        echo "    $track: all $count .sql files parse"
    else
        failed=1
    fi
done

# Every tracked .sql must belong to a track, or it is never parsed.
echo
echo "--- every tracked .sql sits under labs/<track>/"
prefixes=""
for track in "${tracks[@]}"; do
    prefixes="${prefixes:+$prefixes|}labs/$track/"
done
orphans=$(git ls-files '*.sql' | grep -vE "^($prefixes)" || true)
if [ -n "$orphans" ]; then
    echo "    FAIL  tracked .sql outside labs/<track>/ for every track (${tracks[*]}) -- never parsed:"
    printf '%s\n' "$orphans" | sed 's/^/          /'
    failed=1
else
    echo "    OK    none"
fi

echo
if [ "$failed" -eq 0 ]; then
    echo "OK: every .sql file of every track parses (syntax only; names are not validated)"
else
    echo "FAIL: see FAIL lines above"
fi
exit "$failed"
