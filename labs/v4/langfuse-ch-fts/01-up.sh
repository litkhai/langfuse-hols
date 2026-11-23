#!/usr/bin/env bash
# Starts the lab's own ClickHouse next to the shared v4 stack (which it does not touch) and
# checks that the shared stack is reachable. Image: clickhouse/clickhouse-server:$FTS_IMAGE.
#   FTS_IMAGE=26.8.22.13 labs/v4/langfuse-ch-fts/01-up.sh   # same build as the stack, for the version comparison
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lf_ch "SELECT version()" >/dev/null || { echo "✗ shared stack ClickHouse not reachable on :$LF_CH_HTTP — start it with _base/bin/up.sh v4" >&2; exit 1; }
echo "• shared stack ClickHouse $(lf_ch 'SELECT version()')"

docker rm -f "$FTS_CH" >/dev/null 2>&1 || true
docker run -d --name "$FTS_CH" --memory 3g \
  -p "127.0.0.1:$FTS_HTTP:8123" \
  -e CLICKHOUSE_USER=default -e CLICKHOUSE_PASSWORD=lab -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
  --ulimit nofile=262144:262144 \
  "clickhouse/clickhouse-server:$FTS_IMAGE" >/dev/null
for i in $(seq 1 60); do
  fts_ch "SELECT 1" >/dev/null 2>&1 && break
  sleep 1
done
echo "• lab ClickHouse $(fts_ch 'SELECT version()') on 127.0.0.1:$FTS_HTTP (container $FTS_CH, 3 GiB cap)"
