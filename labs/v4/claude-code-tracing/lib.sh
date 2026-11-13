# lib.sh — sourced by this lab's shell scripts. Not executed.
#
#   LAB_DIR       this directory
#   RUN_DIR       $LAB_DIR/.run (gitignored): the installed hook, its venv and state, test repositories, run results
#   LAB_PROJECT   lf-cc-lab — the compose project; containers are lf-cc-lab-<service>-1
#   lab_compose   docker compose for this lab: the _base file plus this lab's overlay, under its own
#                 project name, with the version pins of the v4 track
#
# The secrets file defaults to _base/.env of this clone; LF_ENV_FILE points at another clone's.
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$LAB_DIR/../../../_base/lib/env.sh" v4
RUN_DIR="$LAB_DIR/.run"
LAB_PROJECT=lf-cc-lab
LF_ENV_FILE="${LF_ENV_FILE:-$BASE_DIR/.env}"
export LF_ENV_FILE

lab_compose() {
  local envfiles=(--env-file "$TRACK_DIR/versions.env")
  [[ -f "$LF_ENV_FILE" ]] && envfiles+=(--env-file "$LF_ENV_FILE")
  docker compose -p "$LAB_PROJECT" "${envfiles[@]}" -f "$BASE_DIR/docker-compose.yml" -f "$LAB_DIR/docker-compose.yml" "$@"
}

wait_web() {
  for i in $(seq 1 100); do
    curl -fsS -o /dev/null http://localhost:13000/api/public/health 2>/dev/null && return 0
    sleep 3
  done
  echo "✗ web not healthy; docker logs $LAB_PROJECT-langfuse-web-1" >&2
  return 1
}
