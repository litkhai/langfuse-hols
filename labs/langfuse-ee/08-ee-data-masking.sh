#!/usr/bin/env bash
# 08-ee-data-masking.sh — Server-Side Data Masking (Enterprise), end to end.
#
#   1. Bring up a tiny masking-callback sidecar and wire the WORKER to it
#      (docker-compose.masking.yml).
#   2. Send PII/secret-laden traces via the SDK (OTLP endpoint).
#   3. Prove with ClickHouse SQL that the raw secrets never landed — only the
#      [REDACTED_*] placeholders did.
#
# Masking happens in the ingestion pipeline BEFORE persistence, so ClickHouse is
# the source of truth for "did the secret leak?". This is the SA payoff.
#
# Requires: EE active (license key in .env), the langfuse SDK installed
# (pip install "langfuse>=3"), `jq` optional.
set -euo pipefail
cd "$(dirname "$0")"
. "$(dirname "$0")/_env.sh"; load_env

if [[ -z "${LANGFUSE_EE_LICENSE_KEY:-}" ]]; then
  echo "✗ LANGFUSE_EE_LICENSE_KEY is empty in .env — data masking is an EE feature."
  exit 1
fi

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.ee.yml -f docker-compose.masking.yml)
HOST="${NEXTAUTH_URL:-http://localhost:3000}"

# Pick a Python interpreter: prefer the workshop venv, then python3, then python.
PY="python"
if [[ -x .venv/bin/python ]]; then PY=".venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then PY="python3"
fi

echo "▶ Bringing up the masking sidecar + wiring the worker to it…"
"${COMPOSE[@]}" up -d

echo "▶ Waiting for langfuse-web…"
for i in $(seq 1 60); do
  curl -fsS "${HOST}/api/public/health" >/dev/null 2>&1 && break
  printf '.'; sleep 3
  [[ $i -eq 60 ]] && { echo; echo "⚠ web did not become healthy"; exit 1; }
done
echo " ready."

echo "▶ Sending PII-laden traces (secrets embedded in input/output/metadata)…"
echo "  (using interpreter: ${PY})"
if ! "$PY" 08-generate-pii-traces.py "${1:-12}"; then
  echo "✗ generator failed. Create the venv and install the SDK:"
  echo "    python3 -m venv .venv && ./.venv/bin/pip install 'langfuse>=3'"
  exit 1
fi

echo "▶ Letting the worker ingest + mask (async)…"
sleep 8

echo "▶ Verifying against ClickHouse — raw secrets should be GONE, [REDACTED_*] present:"
"${COMPOSE[@]}" exec -T clickhouse clickhouse-client \
  -u "${CLICKHOUSE_USER:-clickhouse}" --password "${CLICKHOUSE_PASSWORD:-clickhouse}" \
  --multiquery < 08-verify-masking.sql

cat <<EOF

✅ How to read the output above:
  • Section 1 leak counts should be ALL ZERO  → no raw secret reached ClickHouse.
  • Section 2 masked-row count should be > 0   → the sidecar redacted in-flight.
  • Section 3 shows payloads with [REDACTED_API_KEY] / [REDACTED_CC] / etc.

Notes:
  • Masking only applies to the OTLP endpoint (/api/public/otel = SDK v3+).
  • FAIL_CLOSED=true (see docker-compose.masking.yml): if the callback errors,
    the event is DROPPED rather than stored unmasked — the secure default.
  • Tail the sidecar to watch redactions:  docker compose logs -f masking
  • Teardown removes the sidecar too:      ./99-cleanup.sh
EOF
