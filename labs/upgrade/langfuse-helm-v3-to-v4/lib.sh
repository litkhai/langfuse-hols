# Shared settings for this lab. Sourced by every step: `. ./lib.sh`.
# Pins were read on 2026-11-03 (gh release list langfuse/langfuse; langfuse-k8s tags;
# helm show chart oci://ghcr.io/langfuse/langfuse-k8s/charts/langfuse --version …).

LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK="$LAB_DIR/.work"            # generated files, upstream checkout, logs (git-ignored)
mkdir -p "$WORK"

CLUSTER=lf-upgrade               # kind cluster name
KCTX=kind-$CLUSTER
NS=langfuse
V1=langfuse                      # chart v1 release (source)
V2=langfuse-v2                   # chart v2 release (sibling, upstream default name)

CHART=oci://ghcr.io/langfuse/langfuse-k8s/charts/langfuse
CHART_V1=1.5.41                  # last chart v1; appVersion 3.224.1, bundled ClickHouse 25.2
CHART_V2=2.2.1                   # latest chart v2; appVersion 4.70.1, ClickHouse 26.8.36.3

LF_START=3.172.1                 # the old v3 we start from (below the 3.224.1 floor)
LF_V3=3.225.15                   # latest v3 (2026-10-27)
LF_V4=4.72.0                     # latest v4 (2026-10-29)

# Upstream migration procedure (examples/upgrade-v1-to-v2), pinned to a commit.
K8S_REPO=https://github.com/langfuse/langfuse-k8s.git
K8S_SHA=15f31e88d7fbf5554a39524729ed2dee10bff538   # main, 2026-11-02

# MinIO client. The upstream script defaults to quay.io/minio/mc:latest, which answered 401 on
# 2026-11-03 (Docker Hub minio/mc is gone too); the Bitnami MinIO image of chart v1 ships `mc`.
MC_IMAGE=docker.io/bitnamilegacy/minio:2024.12.18-debian-12-r1

# Headless init (LANGFUSE_INIT_*): one org, one project, fixed API keys, one admin user.
# Lab values only; the cluster is local.
LF_PK=pk-lf-upgrade-lab
LF_SK=sk-lf-upgrade-lab
LF_USER=admin@example.com
LF_PASSWORD=upgrade-lab-password
LF_PROJECT=upgrade-lab

kx() { kubectl --context "$KCTX" "$@"; }
hx() { helm --kube-context "$KCTX" "$@"; }
log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Local port for a Service, via a port-forward that this step owns. Prints the URL.
#   url=$(pf web langfuse-web 3000)
pf() {
  local name=$1 svc=$2 port=$3 local_port
  local_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1])')
  kx -n "$NS" port-forward "svc/$svc" "$local_port:$port" >"$WORK/pf-$name.log" 2>&1 &
  echo $! >"$WORK/pf-$name.pid"
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://127.0.0.1:$local_port" && break
    sleep 1
  done
  echo "http://127.0.0.1:$local_port"
}
pf_stop() { [ -f "$WORK/pf-$1.pid" ] && kill "$(cat "$WORK/pf-$1.pid")" 2>/dev/null; rm -f "$WORK/pf-$1.pid"; }

# Postgres and ClickHouse queries inside the store pods.
v1_psql() {
  local pw; pw=$(kx -n "$NS" get secret "$V1-postgresql" -o jsonpath='{.data.postgres-password}' | base64 -d)
  kx -n "$NS" exec -i "$V1-postgresql-0" -- env PGPASSWORD="$pw" psql -U postgres -d postgres_langfuse -tAX "$@"
}
v2_psql() {
  local pw; pw=$(kx -n "$NS" get secret "$V2-postgresql-auth" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
  kx -n "$NS" exec -i "$V2-postgresql-0" -- env PGPASSWORD="$pw" psql -U postgres -d langfuse -tAX "$@"
}
v1_ch() { kx -n "$NS" exec -i "$V1-clickhouse-shard0-0" -- clickhouse-client --password clickhouse-lab "$@"; }
v2_ch() {
  local pw; pw=$(kx -n "$NS" get secret "$V2-clickhouse-auth" -o jsonpath='{.data.password}' | base64 -d)
  kx -n "$NS" exec -i "$V2-clickhouse-0-0-0" -- clickhouse-client --password "$pw" "$@"
}

PYTHON=${PYTHON:-python3.12}      # 3.10+; the venvs below are made with it
PY="$WORK/venv-v3/bin/python"    # SDK v3 (old producer)
PY4="$WORK/venv-v4/bin/python"   # SDK v4 (v4-compatible producer)

# v4 write mode: the ConfigMap that v4-values.yaml mounts with envFrom, then a restart of web and
# worker (the variables are read at start). The worker restarts after web, for the reason in 04.
setmode() {
  kx -n "$NS" create configmap langfuse-v4-migration --from-env-file="$LAB_DIR/modes/$1.env" \
    --dry-run=client -o yaml | kx apply -f - >/dev/null
  kx -n "$NS" rollout restart deploy/"$V2"-web >/dev/null
  kx -n "$NS" rollout status deploy/"$V2"-web --timeout=600s >/dev/null
  kx -n "$NS" rollout restart deploy/"$V2"-worker >/dev/null
  kx -n "$NS" rollout status deploy/"$V2"-worker --timeout=600s >/dev/null
  echo "mode $1: $(kx -n "$NS" get configmap langfuse-v4-migration -o jsonpath='{.data}')"
}
v2_values() { echo -f "$WORK/v2-values.generated.yaml" -f "$LAB_DIR/v2-kind-values.yaml"; }
# HTTP status of a public API call with the lab's keys: api GET /api/public/traces
api() { curl -s -o /dev/null -w '%{http_code}' -u "$LF_PK:$LF_SK" -X "$1" "$url$2" ${3:+-H 'Content-Type: application/json' -d "$3"}; }
