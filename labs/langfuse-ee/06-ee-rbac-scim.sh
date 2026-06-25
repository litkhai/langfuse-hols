#!/usr/bin/env bash
# 06-ee-rbac-scim.sh — Enterprise RBAC, SCIM provisioning & org/project management,
# end to end, with zero UI clicks. Demonstrates the full self-service admin chain:
#
#   ADMIN_API_KEY ─► create Organization ─► mint org-scoped API key
#        org key  ─► create Project ─► mint project API key
#        org key  ─► SCIM: provision users ─► assign org roles
#        org key  ─► assign a PROJECT-LEVEL role that overrides the org role  (EE)
#
# Requires: EE active (run 05 first), `jq`, and ADMIN_API_KEY set in .env.
set -euo pipefail
cd "$(dirname "$0")"
. "$(dirname "$0")/_env.sh"; load_env

command -v jq >/dev/null || { echo "✗ please install jq"; exit 1; }
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
ADMIN="Authorization: Bearer ${ADMIN_API_KEY:?set ADMIN_API_KEY in .env}"

echo "════ 1. Create an organization (Instance Management API, Bearer auth) ════"
ORG=$(curl -fsS -X POST "${HOST}/api/admin/organizations" \
  -H "$ADMIN" -H "Content-Type: application/json" \
  -d '{"name":"Acme Corp","metadata":{"team":"ai-platform"}}')
ORG_ID=$(echo "$ORG" | jq -r '.id')
echo "  org id = $ORG_ID"

echo "════ 2. Mint an organization-scoped API key ════"
ORG_KEY=$(curl -fsS -X POST "${HOST}/api/admin/organizations/${ORG_ID}/apiKeys" \
  -H "$ADMIN" -H "Content-Type: application/json" \
  -d '{"note":"provisioning key (workshop)"}')
ORG_PK=$(echo "$ORG_KEY" | jq -r '.publicKey')
ORG_SK=$(echo "$ORG_KEY" | jq -r '.secretKey')
echo "  org public key = $ORG_PK"

# From here on we authenticate as the ORGANIZATION (Basic auth) — the same
# org-scoped routes an IdP / Terraform / CI pipeline would call.
orgcurl() { curl -fsS -u "${ORG_PK}:${ORG_SK}" "$@"; }

echo "════ 3. Create a project under the org ════"
# retention=0 → keep data forever. (Non-zero needs the data-retention entitlement; see lab 07.)
PROJ=$(orgcurl -X POST "${HOST}/api/public/projects" \
  -H "Content-Type: application/json" \
  -d '{"name":"acme-prod","retention":0,"metadata":{"env":"prod"}}')
PROJ_ID=$(echo "$PROJ" | jq -r '.id')
echo "  project id = $PROJ_ID"

echo "════ 4. Mint a project API key (this is what an app would use to send traces) ════"
PROJ_KEY=$(orgcurl -X POST "${HOST}/api/public/projects/${PROJ_ID}/apiKeys" \
  -H "Content-Type: application/json" -d '{"note":"acme-prod app key"}')
echo "  project public key = $(echo "$PROJ_KEY" | jq -r '.publicKey')"

echo "════ 5. SCIM: provision two users (as an IdP like Okta/Entra would) ════"
scim_user() {  # $1=email  $2=display name
  orgcurl -X POST "${HOST}/api/public/scim/Users" \
    -H "Content-Type: application/scim+json" \
    -d "{\"schemas\":[\"urn:ietf:params:scim:schemas:core:2.0:User\"],
         \"userName\":\"$1\",\"name\":{\"formatted\":\"$2\"},
         \"emails\":[{\"primary\":true,\"value\":\"$1\"}],\"active\":true}"
}
ALICE_ID=$(scim_user "alice@acme.test" "Alice Scientist" | jq -r '.id')
BOB_ID=$(scim_user   "bob@acme.test"   "Bob Auditor"     | jq -r '.id')
echo "  alice id = $ALICE_ID   bob id = $BOB_ID"

echo "════ 6. Assign ORGANIZATION-level roles ════"
# Alice is a full member org-wide; Bob gets the most restrictive org role.
orgcurl -X PUT "${HOST}/api/public/organizations/memberships" \
  -H "Content-Type: application/json" \
  -d "{\"userId\":\"${ALICE_ID}\",\"role\":\"MEMBER\"}" >/dev/null
orgcurl -X PUT "${HOST}/api/public/organizations/memberships" \
  -H "Content-Type: application/json" \
  -d "{\"userId\":\"${BOB_ID}\",\"role\":\"VIEWER\"}" >/dev/null
echo "  alice=MEMBER (org), bob=VIEWER (org)"

echo "════ 7. PROJECT-LEVEL role override (Enterprise feature) ════"
# Bob is only a VIEWER org-wide, but we elevate him to ADMIN *on acme-prod only*.
# Fine-grained per-project roles like this require an EE license.
orgcurl -X PUT "${HOST}/api/public/projects/${PROJ_ID}/memberships" \
  -H "Content-Type: application/json" \
  -d "{\"userId\":\"${BOB_ID}\",\"role\":\"ADMIN\"}" >/dev/null
echo "  bob=ADMIN (project acme-prod) — overrides his org-level VIEWER role"

echo "════ 8. Read back the resulting access matrix ════"
echo "── organization memberships ──"
orgcurl "${HOST}/api/public/organizations/memberships" | jq '.memberships'
echo "── acme-prod project memberships ──"
orgcurl "${HOST}/api/public/projects/${PROJ_ID}/memberships" | jq '.memberships'

cat <<EOF

✅ Provisioned org '${ORG_ID}' with project '${PROJ_ID}', 2 SCIM users and a
   project-level role override — all via API. Verify in the UI:
   ${HOST}  →  switch to 'Acme Corp'  →  Settings → Members.

Recap of the RBAC model exercised here:
  OWNER  full control          ADMIN  manage settings + members
  MEMBER view + create scores   VIEWER read-only
  Org role is the default; a project role overrides it for that one project (EE).
EOF
