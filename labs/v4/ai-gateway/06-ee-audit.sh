#!/usr/bin/env bash
# Step 06 (optional) — the audit log for gateway keys, with and without an Enterprise licence.
#
#   labs/v4/ai-gateway/06-ee-audit.sh      # needs LANGFUSE_EE_LICENSE_KEY in the secrets file
#
# Langfuse 4.75.0 writes audit records on a self-hosted instance only when the licence grants the
# `audit-logs` entitlement (web/src/features/audit-logs/isAuditLogEnabled.ts). This step creates and
# revokes one key in OSS mode, restarts web and worker with the shared EE overlay, does the same
# again, and counts the records. It leaves web and worker in OSS mode afterwards.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env "$LF_ENV_FILE"
: "${LANGFUSE_EE_LICENSE_KEY:?set LANGFUSE_EE_LICENSE_KEY in $LF_ENV_FILE}"
load_gateway_secrets
PY="${PYTHON:-$(cd "$LAB_DIR/../../.." && pwd)/.venv-v4/bin/python}"   # PYTHON=<path> for another venv

echo "▶ OSS mode: create and revoke a key"
"$PY" "$LAB_DIR/06-audit-probe.py" oss

echo "▶ restarting web and worker with the EE overlay"
EE=1 lab_compose up -d langfuse-web langfuse-worker >/dev/null 2>&1
sleep 5; wait_web
echo "▶ EE mode: create and revoke a key"
"$PY" "$LAB_DIR/06-audit-probe.py" ee || rc=$?

echo "▶ back to OSS mode"
lab_compose up -d langfuse-web langfuse-worker >/dev/null 2>&1
sleep 5; wait_web
"$PY" "$LAB_DIR/06-audit-probe.py" judge
exit "${rc:-0}"
