#!/usr/bin/env bash
# Step 07 — start LiteLLM Proxy (and its Postgres) in the same compose project as the gateway (#89).
#
#   labs/v4/ai-gateway/07-litellm-up.sh        # after 01-up.sh; LF_ENV_FILE as for the other steps
#
# First run: generates LITELLM_MASTER_KEY (admin API and UI) and LITELLM_SALT_KEY (encrypts credentials
# stored in its database) into .run/ (mode 600). LiteLLM reads ANTHROPIC_API_KEY from the secrets file.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env "$LF_ENV_FILE"
: "${ANTHROPIC_API_KEY:?missing in $LF_ENV_FILE}"
[[ -s "$RUN_DIR/service-key" ]] || { echo "✗ run 01-up.sh first" >&2; exit 1; }
if [[ ! -s "$RUN_DIR/litellm-master-key" ]]; then
  ( umask 077
    printf 'sk-%s' "$(openssl rand -hex 24)" > "$RUN_DIR/litellm-master-key"
    printf 'sk-%s' "$(openssl rand -hex 24)" > "$RUN_DIR/litellm-salt-key" )
  echo "▶ generated LiteLLM master key and salt key in $RUN_DIR"
fi
load_gateway_secrets
load_litellm_secrets

echo "▶ Starting LiteLLM $(grep -o 'v1\.[0-9.]*' "$LAB_DIR/docker-compose.litellm.yml" | head -1) and its Postgres…"
lab_compose --profile litellm up -d litellm-db litellm
for i in $(seq 1 100); do
  curl -fsS -o /dev/null http://localhost:18440/health/liveliness 2>/dev/null && { echo "  LiteLLM live after ~$((i*3)) s"; break; }
  [[ $i -eq 100 ]] && { echo "✗ LiteLLM not live; docker logs $LAB_PROJECT-litellm-1" >&2; exit 1; }
  sleep 3
done
printf '  image: %s\n' "$(docker inspect -f '{{.Config.Image}}' "$LAB_PROJECT-litellm-1")"
echo "✅ LiteLLM http://localhost:18440 (UI /ui, user admin, password = .run/litellm-master-key) — next: 08-litellm-setup.py"
