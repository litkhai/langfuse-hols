# lib.sh — sourced by this lab's shell scripts. Not executed.
#
#   LAB_DIR       this directory
#   RUN_DIR       $LAB_DIR/.run (gitignored): gateway secrets, issued keys, run results
#   LAB_PROJECT   lf-gateway-lab — the compose project; containers are lf-gateway-lab-<service>-1
#   lab_compose   docker compose for this lab: the _base files plus this lab's overlay, under
#                 its own project name, with the version pins of the v4 track and the lab's
#                 own Langfuse version on top
#
# The secrets file defaults to _base/.env of this clone; LF_ENV_FILE points at another clone's.
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$LAB_DIR/../../../_base/lib/env.sh" v4
RUN_DIR="$LAB_DIR/.run"
LAB_PROJECT=lf-gateway-lab
LF_ENV_FILE="${LF_ENV_FILE:-$BASE_DIR/.env}"
export LF_ENV_FILE
# The gateway needs Langfuse >= 4.75.0 for web and gateway alike; the v4 track pin is older.
# A shell value wins over both env files, so this pin applies to this project only.
export LANGFUSE_VERSION="${GATEWAY_LANGFUSE_VERSION:-4.75.0}"

lab_compose() {
  local envfiles=(--env-file "$TRACK_DIR/versions.env")
  [[ -f "$LF_ENV_FILE" ]] && envfiles+=(--env-file "$LF_ENV_FILE")
  # docker-compose.litellm.yml is always part of the project; its services sit behind the profile
  # "litellm", so they start only with `--profile litellm` (07-litellm-up.sh) and `down` sees them.
  local files=(-f "$BASE_DIR/docker-compose.yml" -f "$LAB_DIR/docker-compose.yml" -f "$LAB_DIR/docker-compose.litellm.yml")
  # EE=1 adds the shared enterprise overlay (LANGFUSE_EE_LICENSE_KEY on web and worker).
  [[ "${EE:-0}" == "1" ]] && files+=(-f "$BASE_DIR/docker-compose.ee.yml")
  docker compose -p "$LAB_PROJECT" "${envfiles[@]}" "${files[@]}" "$@"
}

wait_web() {
  for i in $(seq 1 100); do
    curl -fsS -o /dev/null http://localhost:13000/api/public/health 2>/dev/null && return 0
    sleep 3
  done
  echo "✗ web not healthy; docker logs $LAB_PROJECT-langfuse-web-1" >&2
  return 1
}

load_litellm_secrets() {
  LITELLM_MASTER_KEY="$(cat "$RUN_DIR/litellm-master-key")"
  LITELLM_SALT_KEY="$(cat "$RUN_DIR/litellm-salt-key")"
  export LITELLM_MASTER_KEY LITELLM_SALT_KEY
}

load_gateway_secrets() {
  GW_SERVICE_KEY="$(cat "$RUN_DIR/service-key")"
  GW_JWT_PRIVATE_KEY="$(cat "$RUN_DIR/jwt-private-key.pem")"
  export GW_SERVICE_KEY GW_JWT_PRIVATE_KEY
}
