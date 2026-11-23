#!/usr/bin/env bash
# 03 — Grafana OSS + ClickHouse datasource, provisioned from grafana/ (datasource, dashboard JSON).
# Rebuilds the dashboard JSON from sql/ first, starts the container on 127.0.0.1:$GRAFANA_PORT and
# waits until the datasource answers a query. Anonymous viewers may look; the admin password is
# written to .run/grafana-admin (mode 600).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"
if [[ ! -s "$RUN_DIR/grafana-admin" ]]; then
  (umask 077; openssl rand -hex 16 > "$RUN_DIR/grafana-admin")
fi
export GRAFANA_ADMIN_PASSWORD="$(cat "$RUN_DIR/grafana-admin")"
docker network inspect "$LF_NETWORK" >/dev/null 2>&1 || { echo "✗ network $LF_NETWORK missing: start the shared stack (_base/bin/up.sh v4)" >&2; exit 1; }
python3 "$LAB_DIR/build_dashboard.py"
lab_compose up -d
G="http://127.0.0.1:$GRAFANA_PORT"
for i in $(seq 1 60); do
  curl -fsS "$G/api/health" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$G/api/health" >/dev/null || { echo "✗ Grafana not healthy: docker logs $LAB_PROJECT-grafana-1" >&2; exit 1; }
# The datasource answers: one query through Grafana's own API, as a panel would run it.
body='{"queries":[{"refId":"A","datasource":{"uid":"langfuse-ch"},"rawSql":"SELECT version() AS v","format":1,"queryType":"sql","editorType":"sql"}],"from":"now-1h","to":"now"}'
out="$(curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' -d "$body" "$G/api/ds/query")"
echo "$out" | grep -q '"values":\[\["' || { echo "✗ datasource query failed: $out" >&2; exit 1; }
ver="$(curl -fsS "$G/api/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
plug="$(curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" "$G/api/plugins/grafana-clickhouse-datasource/settings" | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])')"
echo "✓ Grafana $ver, grafana-clickhouse-datasource $plug, ClickHouse $(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"]["A"]["frames"][0]["data"]["values"][0][0])')"
echo "  dashboard: $G/d/langfuse-kr  (admin password: .run/grafana-admin)"
