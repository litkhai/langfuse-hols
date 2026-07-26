#!/usr/bin/env bash
# 09-ee-protected-prompts.sh — Enterprise prompt governance: versioned prompts,
# deployment labels, and PROTECTED LABELS (an EE feature).
#
# Prompts are OLTP objects: they live in POSTGRES (not ClickHouse) — reinforcing
# the two-database model. This lab:
#   1. creates a versioned prompt and moves the `production` label via the API
#   2. resolves the current production prompt (what an app would fetch)
#   3. shows the versions/labels Langfuse stored in Postgres
#   4. shows the audit-log rows the changes generated (ties to lab 07)
#   5. walks the PROTECTED-LABEL governance capstone (UI toggle) + what it enforces
#
# Label PROTECTION is toggled in Project Settings (UI-only; no public API) and is
# enforced per USER ROLE: VIEWER/MEMBER cannot repoint or delete a protected
# `production` label, nor delete the prompt — only ADMIN/OWNER can. (EE-gated.)
#
# Requires: stack up (EE active for the protection capstone), jq, and the project
# keys in .env (LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY).
set -euo pipefail
cd "$(dirname "$0")"
. "$(dirname "$0")/_env.sh"; load_env
command -v jq >/dev/null || { echo "✗ please install jq"; exit 1; }

HOST="${NEXTAUTH_URL:-http://localhost:3000}"
PK="${LANGFUSE_PUBLIC_KEY:?set LANGFUSE_PUBLIC_KEY in .env}"
SK="${LANGFUSE_SECRET_KEY:?set LANGFUSE_SECRET_KEY in .env}"
pcurl() { curl -fsS -u "${PK}:${SK}" "$@"; }   # project-scoped Basic auth
NAME="support-system-prompt"

echo "════ 1. Create v1 of a prompt, labelled 'production' ════"
pcurl -X POST "${HOST}/api/public/v2/prompts" -H "Content-Type: application/json" -d "{
  \"type\":\"text\",\"name\":\"${NAME}\",
  \"prompt\":\"You are Acme's support assistant. Answer in one concise paragraph.\",
  \"labels\":[\"production\"],
  \"config\":{\"temperature\":0.2},
  \"commitMessage\":\"v1 initial\"
}" | jq '{name, version, labels}'

echo "════ 2. Create v2 (stricter) and MOVE 'production' to it ════"
pcurl -X POST "${HOST}/api/public/v2/prompts" -H "Content-Type: application/json" -d "{
  \"type\":\"text\",\"name\":\"${NAME}\",
  \"prompt\":\"You are Acme's senior support assistant. Be concise, cite the KB article id, and never guess.\",
  \"labels\":[\"production\"],
  \"config\":{\"temperature\":0.1},
  \"commitMessage\":\"v2 stricter + cite KB\"
}" | jq '{name, version, labels}'

echo "════ 3. Resolve the current production prompt (what an app fetches) ════"
pcurl "${HOST}/api/public/v2/prompts/${NAME}?label=production" | jq '{name, version, labels, prompt}'

echo "════ 4. Prompts are OLTP → stored in POSTGRES, not ClickHouse ════"
PSQL=(docker compose exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -P pager=off)
"${PSQL[@]}" -c "SELECT version, labels, created_at FROM prompts WHERE name = '${NAME}' ORDER BY version;" \
  || echo "  (the prompts table name can vary by version — list with '\\dt')"

echo "════ 5. Every label change was AUDITED (ties to lab 07) ════"
AUDIT_TBL=$("${PSQL[@]}" -tAc \
  "SELECT table_name FROM information_schema.tables WHERE table_name ILIKE 'audit%' LIMIT 1;" | tr -d '[:space:]')
if [[ -n "$AUDIT_TBL" ]]; then
  "${PSQL[@]}" -c "SELECT created_at, action, resource_type
                   FROM \"${AUDIT_TBL}\" WHERE resource_type ILIKE '%prompt%'
                   ORDER BY created_at DESC LIMIT 5;" \
    || echo "  (no prompt rows in the audit log yet)"
else
  echo "  (no audit table yet — run lab 05 to activate EE first)"
fi

cat <<EOF

════ 6. PROTECT the 'production' label — Enterprise governance capstone ════
Lock the label so it can't be repointed or deleted by mistake:

  UI → Project Settings → Prompts → mark the 'production' label as PROTECTED
       (Owner/Admin only; requires an EE license).

Once protected, the RBAC roles from lab 06 behave like this:
  • Bob   (VIEWER org-wide)  → CANNOT move/delete 'production', CANNOT delete the prompt
  • Alice (MEMBER)          → CANNOT move/delete 'production'
  • Owner / Admin           → CAN still repoint or delete it

This stops an accidental (or unauthorized) production-prompt change — a top ask
for regulated LLM deployments. Protected prompt labels are an EE feature.
EOF
