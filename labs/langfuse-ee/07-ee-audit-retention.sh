#!/usr/bin/env bash
# 07-ee-audit-retention.sh — two more Enterprise features:
#
#   A) Data Retention policy   — set per-project retention via the projects API.
#                                A nightly worker job then deletes traces /
#                                observations / scores older than the window
#                                from ClickHouse (and media from blob storage).
#   B) Audit Logs              — immutable who/what/when records of every config
#                                change, stored in Postgres. We read them back.
#
# Requires: EE active (run 05, then 06), `jq`, ADMIN_API_KEY in .env.
set -euo pipefail
cd "$(dirname "$0")"
. "$(dirname "$0")/_env.sh"; load_env

command -v jq >/dev/null || { echo "✗ please install jq"; exit 1; }
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
ADMIN="Authorization: Bearer ${ADMIN_API_KEY:?set ADMIN_API_KEY in .env}"
ORG_ID="${LANGFUSE_INIT_ORG_ID:-ch-workshop}"
PROJECT_ID="${LANGFUSE_INIT_PROJECT_ID:-llm-observability}"
RETENTION_DAYS="${1:-14}"

echo "════════════════ A) Data Retention ════════════════"
echo "▶ Minting an org-scoped key for '${ORG_ID}' to call the projects API…"
ORG_KEY=$(curl -fsS -X POST "${HOST}/api/admin/organizations/${ORG_ID}/apiKeys" \
  -H "$ADMIN" -H "Content-Type: application/json" -d '{"note":"retention admin (workshop)"}')
ORG_PK=$(echo "$ORG_KEY" | jq -r '.publicKey')
ORG_SK=$(echo "$ORG_KEY" | jq -r '.secretKey')
orgcurl() { curl -fsS -u "${ORG_PK}:${ORG_SK}" "$@"; }

echo "▶ Setting ${RETENTION_DAYS}-day retention on project '${PROJECT_ID}'…"
# A non-zero retention value requires the data-retention entitlement (EE).
# On OSS this same call is rejected — proving the feature is license-gated.
orgcurl -X PUT "${HOST}/api/public/projects/${PROJECT_ID}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${LANGFUSE_INIT_PROJECT_NAME:-LLM Observability}\",\"retention\":${RETENTION_DAYS}}" \
  | jq '{id, name, retentionDays}'

cat <<EOF
  ↳ A nightly job now deletes Traces (by timestamp), Observations (start_time),
    Scores (timestamp) and Media (created_at) older than ${RETENTION_DAYS} days
    straight out of ClickHouse. Minimum allowed window is 3 days. Set 0 to keep
    data forever. Tip: pair with a Blob Storage Export to archive before deletion.
EOF

echo
echo "════════════════ B) Audit Logs ════════════════"
echo "▶ Audit logs are stored in Postgres. Discovering the table…"
PSQL=(docker compose exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -P pager=off)

AUDIT_TBL=$("${PSQL[@]}" -tAc \
  "SELECT table_name FROM information_schema.tables WHERE table_name ILIKE 'audit%' LIMIT 1;" | tr -d '[:space:]')

if [[ -z "$AUDIT_TBL" ]]; then
  echo "⚠ No audit table found yet. Perform an action in the UI/API and retry."
  exit 0
fi
echo "  table = ${AUDIT_TBL}"

echo "▶ Schema:"
"${PSQL[@]}" -c "\d \"${AUDIT_TBL}\""

echo "▶ Most recent audit events (who did what, when) — including the org/project/"
echo "  membership changes lab 06 just made (columns are snake_case in Postgres):"
"${PSQL[@]}" -c "
  SELECT created_at, action, resource_type, resource_id, org_id, COALESCE(api_key_id, user_id) AS actor
  FROM \"${AUDIT_TBL}\"
  ORDER BY created_at DESC
  LIMIT 15;" \
  || "${PSQL[@]}" -c "SELECT * FROM \"${AUDIT_TBL}\" ORDER BY created_at DESC LIMIT 10;"

cat <<EOF

✅ Audit logs capture create/update/delete across API keys, memberships,
   projects, prompts, datasets, dashboards and more — with full before/after
   state. In the UI: Organization → Audit Logs (needs the auditLogs:read scope,
   i.e. Owner/Admin) with time/project filters and CSV export.
EOF
