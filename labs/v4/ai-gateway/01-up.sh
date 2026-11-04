#!/usr/bin/env bash
# Start Langfuse 4.75.0 with the AI Gateway as compose project lf-gateway-lab (web :13000,
# gateway :18480, ClickHouse HTTP :18423). Never touches the shared langfuse-hols-v4-* stack.
#
#   labs/v4/ai-gateway/01-up.sh           # LF_ENV_FILE=<path> reads another clone's _base/.env
#
# First run: generates the two shared secrets the self-hosting page asks for into .run/
# (mode 600): the service key web and gateway use to authenticate each other, and the
# ES256 (P-256) private key web signs the gateway's upload tokens with.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ -f "$LF_ENV_FILE" ]] || { echo "✗ no secrets file at $LF_ENV_FILE (copy _base/.env.example, or set LF_ENV_FILE)" >&2; exit 1; }

mkdir -p "$RUN_DIR" && chmod 700 "$RUN_DIR"
if [[ ! -s "$RUN_DIR/service-key" ]]; then
  ( umask 077
    openssl rand -hex 32 > "$RUN_DIR/service-key"
    # The command from the self-hosting page (SEC1 "EC PRIVATE KEY" PEM).
    openssl ecparam -name prime256v1 -genkey -noout -out "$RUN_DIR/jwt-private-key.pem" )
  echo "▶ generated gateway service key and JWT signing key in $RUN_DIR"
fi
load_gateway_secrets

echo "▶ Starting $LAB_PROJECT (Langfuse $LANGFUSE_VERSION web · worker · ai-gateway + backends)…"
lab_compose up -d

echo "▶ Waiting for web (first boot runs the Postgres and ClickHouse migrations)…"
for i in $(seq 1 120); do
  curl -fsS -o /dev/null http://localhost:13000/api/public/health 2>/dev/null && { echo "  web healthy after ~$((i*3)) s"; break; }
  [[ $i -eq 120 ]] && { echo "✗ web not healthy; docker logs $LAB_PROJECT-langfuse-web-1" >&2; exit 1; }
  sleep 3
done
for probe in health ready; do
  for i in $(seq 1 30); do
    body="$(curl -fsS http://localhost:18480/$probe 2>/dev/null || true)"
    [[ -n "$body" ]] && { echo "  gateway /$probe → $body"; break; }
    [[ $i -eq 30 ]] && { echo "✗ gateway /$probe not answering; docker logs $LAB_PROJECT-ai-gateway-1" >&2; exit 1; }
    sleep 1
  done
done
printf '  versions: web %s · gateway image %s\n' \
  "$(docker inspect -f '{{.Config.Image}}' "$LAB_PROJECT-langfuse-web-1")" \
  "$(docker inspect -f '{{.Config.Image}}' "$LAB_PROJECT-ai-gateway-1")"
echo "✅ UI http://localhost:13000 · gateway http://localhost:18480 — next: 02-setup.py"
