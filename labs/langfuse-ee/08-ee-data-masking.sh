#!/usr/bin/env bash
# 08-ee-data-masking.sh — Server-Side Data Masking (Enterprise), end to end.
#
#   1. Bring up a tiny masking-callback sidecar and wire the WORKER to it
#      (docker-compose.masking.yml).
#   2. Send PII/secret-laden traces via the SDK (OTLP endpoint).
#   3. Prove with ClickHouse SQL that the raw secrets never landed in events_full —
#      only the [REDACTED_*] placeholders did — and EXIT 1 unless the verdict is PASS.
#
# Masking happens in the ingestion pipeline BEFORE persistence, so ClickHouse is
# the source of truth for "did the secret leak?". This is the SA payoff.
#
#   ./08-ee-data-masking.sh [N_TRACES]   # the full lab (default 12 traces)
#   ./08-ee-data-masking.sh --selftest   # positive control: the verdict must FAIL on an
#                                        # empty events_full (needs only the running stack)
#
# Requires: EE active (license key in _base/.env), the langfuse SDK installed
# (pip install -r _base/requirements.txt, Python 3.10+), `jq` optional.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../_base/lib/env.sh"; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

VERIFY_SQL="08-verify-masking.sql"
CH_USER="${CLICKHOUSE_USER:-clickhouse}"
CH_PASSWORD="${CLICKHOUSE_PASSWORD:-clickhouse}"

# run_verify SQL_FILE — run the file in ClickHouse, show its output, and succeed only when
# its last row is `verdict<TAB>PASS`. A ClickHouse error aborts the script (exit 2) — it must
# not be mistaken for a FAIL verdict, least of all in the selftest.
run_verify() {
  local out verdict
  out=$(lf_compose -- exec -T clickhouse clickhouse-client \
          -u "$CH_USER" --password "$CH_PASSWORD" --multiquery < "$1") \
    || { printf '%s\n' "$out"; echo "✗ ClickHouse returned an error running $1"; exit 2; }
  printf '%s\n' "$out"
  verdict=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "verdict" { v = $2 } END { print v }')
  [[ "$verdict" == "PASS" ]]
}

if [[ "${1:-}" == "--selftest" ]]; then
  # A "0 leaks" result proves nothing unless the check can fail. Point the very same SQL at
  # an empty copy of events_full: nothing landed, nothing was masked → it must say FAIL.
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  sed 's/default\.events_full/default.events_full_selftest/g' "$VERIFY_SQL" > "$tmp"
  ch=(lf_compose -- exec -T clickhouse clickhouse-client -u "$CH_USER" --password "$CH_PASSWORD" -q)
  "${ch[@]}" "DROP TABLE IF EXISTS default.events_full_selftest"
  "${ch[@]}" "CREATE TABLE default.events_full_selftest AS default.events_full"
  echo "▶ Running ${VERIFY_SQL} against an EMPTY events_full (expect verdict FAIL)…"
  if run_verify "$tmp"; then
    "${ch[@]}" "DROP TABLE default.events_full_selftest"
    echo "✗ SELFTEST FAILED: an empty table produced verdict PASS — the check cannot fail."
    exit 1
  fi
  "${ch[@]}" "DROP TABLE default.events_full_selftest"
  echo "✅ Selftest OK: the empty table produced verdict FAIL, so a PASS means something."
  exit 0
fi

if [[ -z "${LANGFUSE_EE_LICENSE_KEY:-}" ]]; then
  echo "✗ LANGFUSE_EE_LICENSE_KEY is empty in _base/.env — data masking is an EE feature."
  exit 1
fi

COMPOSE=(lf_compose ee masking --)
HOST="${NEXTAUTH_URL:-http://localhost:3000}"

# Pick a Python interpreter: an activated venv, then the lab's or the repository's
# .venv, then python3, then python.
PY="python"
if [[ -n "${VIRTUAL_ENV:-}" && -x "$VIRTUAL_ENV/bin/python" ]]; then PY="$VIRTUAL_ENV/bin/python"
elif [[ -x .venv/bin/python ]]; then PY=".venv/bin/python"
elif [[ -x ../../.venv/bin/python ]]; then PY="../../.venv/bin/python"
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
  echo "✗ generator failed. Create the venv and install the SDK (Python 3.10+):"
  echo "    python3 -m venv .venv && ./.venv/bin/pip install -r ../../_base/requirements.txt"
  exit 1
fi

echo "▶ Letting the worker ingest + mask (async)…"
sleep 8

echo "▶ Verifying against ClickHouse (events_full) — raw secrets should be GONE, [REDACTED_*] present:"
if ! run_verify "$VERIFY_SQL"; then
  echo
  echo "✗ MASKING VERDICT: FAIL — see the counts above (no pii-demo rows, no placeholders, or a leaked secret)."
  echo "  If the counts are all zero the traces may not be ingested yet: wait a few seconds and re-run"
  echo "  the SQL (docker exec … < ${VERIFY_SQL}), or check:  docker logs langfuse-hols-masking-1"
  exit 1
fi

cat <<EOF

✅ MASKING VERDICT: PASS. How to read the output above:
  • Section 1 leak counts should be ALL ZERO  → no raw secret reached ClickHouse.
  • Section 2 masked-row counts should be > 0  → the sidecar redacted in-flight.
  • Section 3 shows payloads and metadata with [REDACTED_API_KEY] / [REDACTED_CC] / etc.
  • The last row is the verdict; this script exits 1 when it is FAIL.

Notes:
  • Masking only applies to the OTLP endpoint (/api/public/otel = SDK v3+).
  • FAIL_CLOSED=true (see docker-compose.masking.yml): if the callback errors,
    the event is DROPPED rather than stored unmasked — the secure default.
  • Tail the sidecar to watch redactions:  docker logs -f langfuse-hols-masking-1
  • Positive control (the verdict must FAIL on an empty table):  ./08-ee-data-masking.sh --selftest
  • Teardown removes the sidecar too:      ./99-cleanup.sh
EOF
