#!/usr/bin/env bash
# 05-ee-activate.sh — switch the running stack into Enterprise Edition.
#
# Restarts langfuse-web + langfuse-worker with the EE overlay so the license key
# (and ADMIN_API_KEY) are injected, then verifies the license took effect.
#
#   1. Put your key in .env:   LANGFUSE_EE_LICENSE_KEY=<your-key>
#   2. ./05-ee-activate.sh
set -euo pipefail
cd "$(dirname "$0")"

set -a; [[ -f .env ]] && . ./.env; set +a

if [[ -z "${LANGFUSE_EE_LICENSE_KEY:-}" ]]; then
  echo "✗ LANGFUSE_EE_LICENSE_KEY is empty in .env. Paste your enterprise key first."
  exit 1
fi

echo "▶ Re-deploying with the Enterprise overlay (license key + admin API)…"
docker compose -f docker-compose.yml -f docker-compose.ee.yml up -d

HOST="${NEXTAUTH_URL:-http://localhost:3000}"
echo "▶ Waiting for langfuse-web to come back…"
for i in $(seq 1 60); do
  curl -fsS "${HOST}/api/public/health" >/dev/null 2>&1 && break
  printf '.'; sleep 3
  [[ $i -eq 60 ]] && { echo; echo "⚠ web did not become healthy"; exit 1; }
done
echo " ready."

# A clean way to prove EE is active: the Instance Management API (/api/admin/*)
# only responds when a valid license key is present. 401/403 = key not active.
echo "▶ Verifying Enterprise activation via the Instance Management API…"
code=$(curl -s -o /tmp/lf_admin.json -w '%{http_code}' \
  -H "Authorization: Bearer ${ADMIN_API_KEY:-}" \
  "${HOST}/api/admin/organizations")

if [[ "$code" == "200" ]]; then
  echo "✅ Enterprise active. Admin API reachable. Current organizations:"
  cat /tmp/lf_admin.json; echo
  cat <<EOF

Next, exercise the enterprise features:
  ./06-ee-rbac-scim.sh        # org/project provisioning, SCIM users, project-level RBAC
  ./07-ee-audit-retention.sh  # audit logs + data-retention policy

In the UI you will now also see (Owner/Admin only):
  • Project Settings → Data Retention
  • Organization → Audit Logs
  • Organization → API Keys (organization-scoped)
  • Project members can be given per-PROJECT roles (not just org-wide)
EOF
else
  echo "⚠ Admin API returned HTTP $code."
  echo "  • 401/403 → license key not recognized, or ADMIN_API_KEY mismatch."
  echo "  • Check activation in the logs:"
  echo "      docker compose logs langfuse-web | grep -i -E 'license|entitlement'"
fi
