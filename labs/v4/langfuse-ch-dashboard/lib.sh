# lib.sh — sourced by this lab's shell scripts. Not executed.
#
#   LAB_DIR       this directory
#   RUN_DIR       $LAB_DIR/.run (gitignored): the Grafana admin password
#   LAB_PROJECT   lf-ch-dashboard — the compose project of this lab's one container (Grafana)
#   GRAFANA_PORT  58300 on 127.0.0.1 (override with GRAFANA_PORT=…)
#   PY            the v4 track's virtual environment (.venv-v4 at the repository root, or $PY)
#   lab_compose   docker compose for this lab: Grafana only, attached to the shared stack's network
#
# The shared v4 stack (_base/bin/up.sh v4) must already be up; this lab never starts or stops it.
# The secrets file defaults to _base/.env of this clone; LF_ENV_FILE points at another clone's.
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$LAB_DIR/../../../_base/lib/env.sh" v4
RUN_DIR="$LAB_DIR/.run"
LAB_PROJECT=lf-ch-dashboard
LF_ENV_FILE="${LF_ENV_FILE:-$BASE_DIR/.env}"
export LF_ENV_FILE
load_env "$LF_ENV_FILE"
export GRAFANA_PORT="${GRAFANA_PORT:-58300}"
export LF_NETWORK="${LF_PROJECT}_default"
PY="${PY:-$BASE_DIR/../.venv-v4/bin/python}"

lab_compose() {
  docker compose -p "$LAB_PROJECT" -f "$LAB_DIR/docker-compose.yml" "$@"
}
