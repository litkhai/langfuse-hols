#!/usr/bin/env bash
# 04-db-separation.sh — two Langfuse instances on ONE ClickHouse server, one database and one user each.
#
#   A: web :3100 + worker, CLICKHOUSE_DB=lf_a, ClickHouse user lf_a (GRANT ALL ON lf_a.* only)
#   B: web :3200 + worker, CLICKHOUSE_DB=lf_b, ClickHouse user lf_b (GRANT ALL ON lf_b.* only)
# Postgres databases lf_a / lf_b, Redis logical DBs 1 / 2 and MinIO prefixes a/ b/ on the stack's servers
# (overlay docker-compose.dbsep.yml). The stack's own web + worker are stopped meanwhile, so two Langfuse
# pairs run, not three.
#
# Steps: (1) start A before its database exists — does the migration create it? (2) create both databases,
# start both, wait for migrations; (3) ingest 100 traces into each over OTLP, read one back over the public
# API, and try A's key on B's trace; (4) as user lf_a: read lf_a, read lf_b, read system tables; (5) list what
# the two Langfuse users ran outside their database and every error they got; (6) clean up (CLEANUP=0 keeps
# the instances running). Writes results/04-db-separation.txt. Ends on the normal OSS stack.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OUT="$RESULTS/04-db-separation.txt"
exec > >(tee "$OUT") 2>&1
CLEANUP="${CLEANUP:-1}"
dc() { ops_compose dbsep -- --profile dbsep "$@"; }
chu() { local u="$1" pw="$2"; shift 2
  docker exec -i "$LF_PROJECT-clickhouse-1" clickhouse-client -u "$u" --password "$pw" -q "$1" 2>&1 | sed 's/^/    /' | cut -c1-240 || true; }
psql_() { docker exec -i "$LF_PROJECT-postgres-1" psql -U "${POSTGRES_USER:-postgres}" -tAc "$1"; }
health() { curl -fsS -o /dev/null "http://localhost:$1/api/public/health" 2>/dev/null; }
wait_web() { for _ in $(seq 1 90); do health "$1" && return 0; sleep 4; done; return 1; }
T0=$(date -u '+%Y-%m-%d %H:%M:%S')

echo "== 04 db separation — $(date -u '+%Y-%m-%dT%H:%M:%SZ'), Langfuse $(docker inspect -f '{{.Config.Image}}' "$LF_PROJECT-langfuse-web-1" | sed 's/.*://'), ClickHouse $(ch 'SELECT version()')"
docker stop "$LF_PROJECT-langfuse-web-1" "$LF_PROJECT-langfuse-worker-1" >/dev/null
dc rm -sf lf-a-web lf-a-worker lf-b-web lf-b-worker >/dev/null 2>&1 || true

echo "-- setup: Postgres databases, ClickHouse users (no ClickHouse database yet)"
for x in a b; do
  [[ "$(psql_ "SELECT 1 FROM pg_database WHERE datname='lf_$x'")" == 1 ]] || psql_ "CREATE DATABASE lf_$x" >/dev/null
  ch "DROP DATABASE IF EXISTS lf_$x SYNC"
done
# The stack's `clickhouse` user has no access management, so the users come from a users.d file.
docker cp "$HERE/clickhouse-users-dbsep.xml" "$LF_PROJECT-clickhouse-1:/etc/clickhouse-server/users.d/zz-dbsep.xml"
for _ in $(seq 1 30); do chu lf_b dbsep-test-b "SELECT 1" | grep -q '^ *1$' && break; sleep 1; done
for x in a b; do echo "  user lf_$x grants (SHOW GRANTS as lf_$x): $(chu "lf_$x" "dbsep-test-$x" "SHOW GRANTS" | tr -s ' \n' ' ')"; done

echo "-- (1) start A while database lf_a does not exist"
dc up -d --no-deps lf-a-web >/dev/null 2>&1
for _ in $(seq 1 60); do   # Postgres migrations run first (449 of them on a new database), then ClickHouse
  health 3100 && break
  docker logs "$LF_PROJECT-lf-a-web-1" 2>&1 | grep -qiE "clickhouse migrations failed|UNKNOWN_DATABASE|Code: 81" && break
  sleep 5
done
echo "  web A health: $(health 3100 && echo up || echo down)  database lf_a exists: $(ch "SELECT count() FROM system.databases WHERE name='lf_a'")"
docker logs "$LF_PROJECT-lf-a-web-1" 2>&1 | grep -iE "migrat|database|error|UNKNOWN_DATABASE|code: 81" | grep -v "^\s*$" | grep -viE "Applying migration|migrations found|Datasource" | head -6 | cut -c1-220 | sed 's/^/  log: /' || true
dc rm -sf lf-a-web >/dev/null 2>&1

echo "-- (2) admin creates lf_a and lf_b; start both instances"
ch "CREATE DATABASE IF NOT EXISTS lf_a; CREATE DATABASE IF NOT EXISTS lf_b"
dc up -d --no-deps lf-a-web lf-a-worker lf-b-web lf-b-worker >/dev/null 2>&1
wait_web 3100 && wait_web 3200 && echo "  web A and web B healthy"
for x in a b; do
  echo "  lf_$x: $(ch "SELECT count() FROM system.tables WHERE database='lf_$x'") tables; latest migration: $(ch "SELECT version, dirty FROM lf_$x.schema_migrations ORDER BY sequence DESC LIMIT 1" | tr '\t' ' ')"
done
echo "  default.schema_migrations rows written by lf_a/lf_b: $(ch "SELECT count() FROM system.query_log WHERE user IN ('lf_a','lf_b') AND has(tables,'default.schema_migrations')")"
shipped=$(docker exec "$LF_PROJECT-lf-a-web-1" sh -c 'ls /app/packages/shared/clickhouse/migrations/unclustered/*.up.sql | wc -l')
echo "  migrations shipped in the image: $shipped"

echo "-- (3) ingest 100 traces into each, read back"
for x in a b; do
  port=$([[ $x == a ]] && echo 3100 || echo 3200)
  LANGFUSE_HOST="http://localhost:$port" LANGFUSE_PUBLIC_KEY="pk-lf-dbsep-$x" LANGFUSE_SECRET_KEY="sk-lf-dbsep-$x" \
    "$PY" "$HERE/loadgen.py" --run-id "dbsep-$x" --rpm 600 --seconds 10 --prompt-bytes 500 --output-bytes 200 |
    jq -r '"  \(.run_id): sent \(.sent_obs) obs, accepted \(.accepted_obs), http \(.http)"'
done
sleep 15
for x in a b; do
  echo "  lf_$x.events_full rows tagged dbsep-$x: $(ch "SELECT count() FROM lf_$x.events_full WHERE has(tags,'dbsep-$x')")  — default.events_full rows tagged dbsep-$x: $(ch "SELECT count() FROM default.events_full WHERE has(tags,'dbsep-$x')")"
done
ta=$(ch "SELECT trace_id FROM lf_a.events_full WHERE has(tags,'dbsep-a') LIMIT 1")
tb=$(ch "SELECT trace_id FROM lf_b.events_full WHERE has(tags,'dbsep-b') LIMIT 1")
code() { curl -s -o /dev/null -w '%{http_code}' -u "$1" "$2"; }
echo "  A key, A trace  GET :3100/api/public/traces/{id}: $(code pk-lf-dbsep-a:sk-lf-dbsep-a "http://localhost:3100/api/public/traces/$ta")"
echo "  B key, B trace  GET :3200/api/public/traces/{id}: $(code pk-lf-dbsep-b:sk-lf-dbsep-b "http://localhost:3200/api/public/traces/$tb")"
echo "  A key, B trace  GET :3100/api/public/traces/{id}: $(code pk-lf-dbsep-a:sk-lf-dbsep-a "http://localhost:3100/api/public/traces/$tb")"
echo "  A key on B's web GET :3200/api/public/traces/{id}: $(code pk-lf-dbsep-a:sk-lf-dbsep-a "http://localhost:3200/api/public/traces/$tb")"
echo "  A: v2 observations of A's trace: $(curl -s -u pk-lf-dbsep-a:sk-lf-dbsep-a "http://localhost:3100/api/public/v2/observations?traceId=$ta" | jq '.data | length') rows"

echo "-- (4) as ClickHouse user lf_a"
echo "  SELECT count() FROM lf_a.events_full:"; chu lf_a dbsep-test-a "SELECT count() FROM lf_a.events_full"
echo "  SELECT count() FROM lf_b.events_full:"; chu lf_a dbsep-test-a "SELECT count() FROM lf_b.events_full"
echo "  SELECT count() FROM default.events_full:"; chu lf_a dbsep-test-a "SELECT count() FROM default.events_full"
echo "  SHOW DATABASES:"; chu lf_a dbsep-test-a "SHOW DATABASES" | tr '\n' ' '; echo
echo "  system.tables rows outside lf_a:"; chu lf_a dbsep-test-a "SELECT count() FROM system.tables WHERE database NOT IN ('lf_a','system','INFORMATION_SCHEMA','information_schema')"
echo "  SELECT count() FROM system.parts (no grant):"; chu lf_a dbsep-test-a "SELECT count() FROM system.parts"
echo "  SELECT count() FROM system.query_log (no grant):"; chu lf_a dbsep-test-a "SELECT count() FROM system.query_log"
echo "  lf_probe (ALL ON lf_a.* + SELECT ON system.parts, system.mutations, system.query_log) — parts by database:"
chu lf_probe dbsep-test-probe "SELECT database, count() FROM system.parts WHERE active GROUP BY database ORDER BY database"
echo "  lf_probe — mutations by database:"
chu lf_probe dbsep-test-probe "SELECT database, count() FROM system.mutations GROUP BY database ORDER BY database"
echo "  lf_probe — system.query_log rows by user (other users' queries included?):"
chu lf_probe dbsep-test-probe "SELECT user, count() FROM system.query_log GROUP BY user ORDER BY user"
echo "  lf_probe — one query text of user lf_b:"
chu lf_probe dbsep-test-probe "SELECT substring(replaceAll(query, '\n', ' '), 1, 150) FROM system.query_log WHERE user = 'lf_b' AND query_kind = 'Select' LIMIT 1"

echo "-- (5) what Langfuse ran as lf_a / lf_b since $T0 UTC"
ch "SYSTEM FLUSH LOGS"
echo "  queries by user and kind:"
ch "SELECT user, query_kind, count() FROM system.query_log WHERE event_time >= '$T0' AND user IN ('lf_a','lf_b') AND type IN ('QueryFinish','ExceptionBeforeStart','ExceptionWhileProcessing') GROUP BY ALL ORDER BY ALL" | sed 's/^/    /'
echo "  databases touched (from query_log.databases):"
ch "SELECT user, arrayJoin(databases) d, count() FROM system.query_log WHERE event_time >= '$T0' AND user IN ('lf_a','lf_b') GROUP BY ALL ORDER BY ALL" | sed 's/^/    /'
echo "  errors (exception code, first 160 chars):"
ch "SELECT user, exception_code, count(), any(substring(replaceAll(exception, '\n', ' '), 1, 160)) FROM system.query_log WHERE event_time >= '$T0' AND user IN ('lf_a','lf_b') AND exception_code != 0 GROUP BY user, exception_code ORDER BY user, exception_code" | sed 's/^/    /'
echo "  worker/web log lines with ACCESS_DENIED or 'Not enough privileges':"
for c in lf-a-web lf-a-worker lf-b-web lf-b-worker; do
  printf '    %s: %s\n' "$c" "$(docker logs "$LF_PROJECT-$c-1" 2>&1 | grep -ciE 'ACCESS_DENIED|Not enough privileges' || true)"
done
echo "  Redis keys in DB 1 / DB 2: $(docker exec "$LF_PROJECT-redis-1" redis-cli -a "${REDIS_AUTH:-myredissecret}" --no-auth-warning -n 1 DBSIZE) / $(docker exec "$LF_PROJECT-redis-1" redis-cli -a "${REDIS_AUTH:-myredissecret}" --no-auth-warning -n 2 DBSIZE)"

if [[ "$CLEANUP" == 1 ]]; then
  echo "-- (6) cleanup"
  dc rm -sf lf-a-web lf-a-worker lf-b-web lf-b-worker >/dev/null 2>&1
  for x in a b; do
    ch "DROP DATABASE IF EXISTS lf_$x SYNC"
    psql_ "DROP DATABASE IF EXISTS lf_$x" >/dev/null
  done
  docker exec -u 0 "$LF_PROJECT-clickhouse-1" rm -f /etc/clickhouse-server/users.d/zz-dbsep.xml
  docker exec "$LF_PROJECT-redis-1" sh -c "redis-cli -a '${REDIS_AUTH:-myredissecret}' --no-auth-warning -n 1 FLUSHDB; redis-cli -a '${REDIS_AUTH:-myredissecret}' --no-auth-warning -n 2 FLUSHDB" >/dev/null
  docker exec "$LF_PROJECT-minio-1" sh -c "mc alias set lab http://localhost:9000 '${MINIO_ROOT_USER:-minio}' '${MINIO_ROOT_PASSWORD:-miniosecret}' >/dev/null; mc rm --recursive --force lab/langfuse/a/ >/dev/null; mc rm --recursive --force lab/langfuse/b/ >/dev/null" || true
  ops_restore
  echo "  done: A and B removed, the stack's web + worker are back"
fi
