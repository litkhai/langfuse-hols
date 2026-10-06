#!/usr/bin/env bash
# 11-ee-parquet-export.sh — export ClickHouse-backed observations to Parquet on object
# storage, and read them back. The enterprise data-platform / archival story.
#
#   A) Langfuse feature : configure a SCHEDULED blob-storage export (Parquet) via
#                         the Org API, pointing at the workshop MinIO bucket. On v4 the
#                         export source is the enriched observations ("OBSERVATIONS_V2");
#                         the legacy traces/observations sources are rejected with HTTP 400.
#   B) ClickHouse primitive that powers it: INSERT INTO FUNCTION s3(...) SELECT
#                         ... 'Parquet' from events_full, then read it back with s3().
#                         Fully live & verifiable — no waiting on the scheduler.
#   C) Pairs with lab 07 : archive-then-delete (export before retention deletes).
#
# Requires: stack up + EE active (run 05 first), jq, ADMIN_API_KEY in _base/.env.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"
command -v jq >/dev/null || { echo "✗ please install jq"; exit 1; }

HOST="${NEXTAUTH_URL:-http://localhost:3000}"
ADMIN="Authorization: Bearer ${ADMIN_API_KEY:?set ADMIN_API_KEY in _base/.env}"
ORG_ID="${LANGFUSE_INIT_ORG_ID:-ch-workshop}"
PROJECT_ID="${LANGFUSE_INIT_PROJECT_ID:-llm-observability}"
BUCKET="${LANGFUSE_S3_BATCH_EXPORT_BUCKET:-langfuse}"
MK_USER="${MINIO_ROOT_USER:-minio}"
MK_PASS="${MINIO_ROOT_PASSWORD:-miniosecret}"

echo "════════════ A) Configure a scheduled Parquet export (Langfuse Org API) ════════════"
echo "▶ Minting an org-scoped key for '${ORG_ID}'…"
ORG_KEY=$(curl -fsS -X POST "${HOST}/api/admin/organizations/${ORG_ID}/apiKeys" \
  -H "$ADMIN" -H "Content-Type: application/json" -d '{"note":"parquet export (workshop)"}')
ORG_PK=$(echo "$ORG_KEY" | jq -r '.publicKey'); ORG_SK=$(echo "$ORG_KEY" | jq -r '.secretKey')
orgcurl() { curl -fsS -u "${ORG_PK}:${ORG_SK}" "$@"; }

put_integration() {  # $1 = fileType. Captures body to /tmp/lf_blob.json, echoes HTTP code.
  curl -s -o /tmp/lf_blob.json -w '%{http_code}' -u "${ORG_PK}:${ORG_SK}" \
    -X PUT "${HOST}/api/public/integrations/blob-storage" -H "Content-Type: application/json" -d "{
      \"projectId\":\"${PROJECT_ID}\",\"type\":\"S3_COMPATIBLE\",\"bucketName\":\"${BUCKET}\",
      \"endpoint\":\"http://minio:9000\",\"region\":\"auto\",\"accessKeyId\":\"${MK_USER}\",
      \"secretAccessKey\":\"${MK_PASS}\",\"prefix\":\"exports/langfuse/\",\"forcePathStyle\":true,
      \"fileType\":\"$1\",\"exportFrequency\":\"hourly\",\"exportMode\":\"FULL_HISTORY\",
      \"exportSource\":\"OBSERVATIONS_V2\",\"enabled\":true}"
}

echo "▶ PUT /api/public/integrations/blob-storage → try Parquet first…"
code=$(put_integration PARQUET)
if [[ "$code" == "200" ]]; then
  echo "  ✅ Parquet scheduled export configured:"
  jq '{type, bucketName, fileType, exportSource, exportFrequency, exportMode, enabled}' /tmp/lf_blob.json
else
  echo "  ⚠ HTTP ${code}: this Langfuse version rejected the integration request —"
  jq -c '.error // .message' /tmp/lf_blob.json 2>/dev/null | sed 's/^/     /'
  echo "  ↳ Langfuse 4.48.0 accepts fileType=PARQUET with the OBSERVATIONS_V2 export source"
  echo "    (measured 2026-10-02); the previous pin, v3.197.1, answered HTTP 400 (JSON/CSV/JSONL"
  echo "    only). The published OpenAPI spec can be ahead of — or behind — your running image."
  echo "    Falling back to JSONL for the scheduled job; ClickHouse still writes TRUE Parquet"
  echo "    in Part B below."
  code=$(put_integration JSONL)
  if [[ "$code" == "200" ]]; then
    echo "  ✅ JSONL scheduled export configured (use a newer image to schedule Parquet):"
    jq '{type, bucketName, fileType, exportSource, exportFrequency, exportMode, enabled}' /tmp/lf_blob.json
  else
    echo "  ⚠ HTTP ${code} again — confirm fields against your version's API reference:"
    cat /tmp/lf_blob.json
  fi
fi

cat <<'EOF'
  ↳ Langfuse's worker will now, on schedule (every 20 min / hourly / daily /
    weekly), stream the enriched observations (and scores) to Parquet in the bucket.
    That scheduled job runs the SAME ClickHouse primitive Part B demonstrates live.
    (Per the API reference, Parquet observation exports omit the model-price columns
    input_price / output_price / total_price.)
EOF

echo
echo "════════════ B) The ClickHouse primitive, live (INSERT INTO FUNCTION s3 → read back) ════════════"
CH=(lf_compose -- exec -T clickhouse clickhouse-client
    -u "${CLICKHOUSE_USER:-clickhouse}" --password "${CLICKHOUSE_PASSWORD:-clickhouse}")
S3="http://minio:9000/${BUCKET}/exports/manual/events_full.parquet"

echo "▶ ClickHouse version (Parquet export failures surface reliably on >= 25.11):"
"${CH[@]}" -q "SELECT version();"

echo "▶ Writing active observations (events_full) to Parquet on MinIO…"
"${CH[@]}" -q "INSERT INTO FUNCTION s3('${S3}', '${MK_USER}', '${MK_PASS}', 'Parquet')
  SELECT * FROM default.events_full FINAL WHERE is_deleted = 0
  SETTINGS s3_truncate_on_insert = 1;"

echo "▶ Reading the Parquet back from MinIO (round-trip proof):"
rows_src=$("${CH[@]}" -q "SELECT count() FROM default.events_full FINAL WHERE is_deleted = 0;")
rows_pq=$("${CH[@]}" -q "SELECT count()
  FROM s3('${S3}', '${MK_USER}', '${MK_PASS}', 'Parquet');")
echo "  rows in events_full (FINAL, active) = ${rows_src}"
echo "  rows read back from the Parquet     = ${rows_pq}"
if [[ "$rows_src" != "$rows_pq" || "$rows_src" == "0" ]]; then
  echo "✗ Round trip FAILED: the Parquet file does not hold the rows that were written."
  exit 1
fi
echo "  ✅ ${rows_src} == ${rows_pq}"

echo "▶ Schema ClickHouse inferred from the exported Parquet (first 15 columns):"
"${CH[@]}" -q "DESCRIBE TABLE s3('${S3}', '${MK_USER}', '${MK_PASS}', 'Parquet')
  SETTINGS describe_compact_output = 1 FORMAT PrettyCompact;" | head -18

cat <<EOF

════════════ C) Archive-then-delete (pairs with lab 07) ════════════
The safe pattern behind a data-retention policy:
  1. lab 11 → export/archive observations to Parquet on object storage (this script)
  2. lab 07 → set a retention window; the nightly worker deletes old rows from CH
The Parquet archive outlives the ClickHouse rows and stays queryable by
ClickHouse (s3()/file()), DuckDB, Athena, Spark, …

Inspect the objects: MinIO console http://localhost:9091  (${MK_USER} / ${MK_PASS})
  → bucket '${BUCKET}'  →  exports/manual/  and  exports/langfuse/ (once the job runs).
EOF
