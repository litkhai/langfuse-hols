#!/usr/bin/env bash
# 10-ee-instance-governance.sh — two instance-level Enterprise controls:
#   A) UI Customization      — co-brand the UI + point help/feedback links inward
#   B) Organization Creators — restrict WHO may create new organizations
#
# Both are env-var driven (EE-gated) and injected via docker-compose.governance.yml.
# We redeploy langfuse-web, then PROVE the vars are live inside the container.
#
# Requires: EE active (license key in .env).
set -euo pipefail
cd "$(dirname "$0")"
. "$(dirname "$0")/_env.sh"; load_env

if [[ -z "${LANGFUSE_EE_LICENSE_KEY:-}" ]]; then
  echo "✗ LANGFUSE_EE_LICENSE_KEY is empty in .env — these are EE features."
  exit 1
fi

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.ee.yml -f docker-compose.governance.yml)
HOST="${NEXTAUTH_URL:-http://localhost:3000}"

echo "▶ Redeploying langfuse-web with the governance overlay…"
"${COMPOSE[@]}" up -d

echo "▶ Waiting for langfuse-web…"
for i in $(seq 1 60); do
  curl -fsS "${HOST}/api/public/health" >/dev/null 2>&1 && break
  printf '.'; sleep 3
  [[ $i -eq 60 ]] && { echo; echo "⚠ web did not become healthy"; exit 1; }
done
echo " ready."

echo "▶ Proving the governance env is injected into the running container:"
"${COMPOSE[@]}" exec -T langfuse-web env \
  | grep -E 'LANGFUSE_UI_|LANGFUSE_ALLOWED_ORGANIZATION_CREATORS' | sort \
  || echo "  (no matching vars found — check the overlay merged in)"

cat <<EOF

✅ Governance config active. Verify in the UI (${HOST}):
  A) UI Customization
     • Custom logo (light/dark) shows top-left
     • Menu 'Docs' / 'Support' / feedback links now point to your URLs
  B) Organization Creators
     • Only LANGFUSE_ALLOWED_ORGANIZATION_CREATORS may create a new org;
       everyone else no longer sees the 'New Organization' action.
       (Existing orgs and their members are unaffected.)

Tune any value in .env (LANGFUSE_UI_* / LANGFUSE_ALLOWED_ORGANIZATION_CREATORS),
then re-run this script to roll it out.
EOF
