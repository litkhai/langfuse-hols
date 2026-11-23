#!/usr/bin/env bash
# 06-bench-up.sh — a separate ClickHouse server for the benchmark, so 100,000-vector tables and
# their index builds do not load the shared Langfuse ClickHouse. Same version as the v4 track
# (CLICKHOUSE_VERSION in _base/v4/versions.env), 4 GB memory cap, HTTP on 127.0.0.1:28123.
# The default user has no password and is reachable only from this machine.
set -euo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$LAB/../../../_base/lib/env.sh" v4
load_env "$TRACK_DIR/versions.env"
NAME=lf-ch-vector-bench
PORT="${BENCH_PORT:-28123}"
if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" --memory 4g \
    -p "127.0.0.1:$PORT:8123" \
    -e CLICKHOUSE_SKIP_USER_SETUP=1 \
    --ulimit nofile=262144:262144 \
    "clickhouse/clickhouse-server:$CLICKHOUSE_VERSION" >/dev/null
fi
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:$PORT/ping" >/dev/null; then
    echo "bench ClickHouse $(curl -s "http://127.0.0.1:$PORT/?query=SELECT+version()") on 127.0.0.1:$PORT (container $NAME)"
    exit 0
  fi
  sleep 1
done
echo "bench ClickHouse did not answer on $PORT" >&2
exit 1
