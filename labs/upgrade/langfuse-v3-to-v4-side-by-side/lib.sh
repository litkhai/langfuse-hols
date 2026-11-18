# Shared settings for this lab. Sourced by every step: `. ./lib.sh`.
# Pins read on 2026-11-18: gh release list langfuse/langfuse; helm show chart
# oci://ghcr.io/langfuse/langfuse-k8s/charts/langfuse; Docker Hub tag API.

LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK="$LAB_DIR/.work"            # generated files, logs, dumps (git-ignored)
RES="$LAB_DIR/results"           # measured results (committed)
mkdir -p "$WORK" "$RES"

CLUSTER=lf-sbs                   # kind cluster name
KCTX=kind-$CLUSTER
NS=langfuse
V3=lf-v3                         # chart v1 release, Langfuse v3 (the running deployment)
V4=lf-v4                         # chart v2 release, Langfuse v4 (the new one, side by side)

CHART=oci://ghcr.io/langfuse/langfuse-k8s/charts/langfuse
CHART_V1=1.5.41                  # last chart v1; bundles Bitnami ClickHouse 25.2.1, Postgres 17.3.0, Valkey 8.0.2
CHART_V2=2.2.5                   # latest chart v2 (2026-11-18), appVersion 4.80.0; the image tag is set below

LF_V3=3.172.1                    # the v3 we start from
LF_V4=4.82.0                     # latest v4 (2026-11-17)

# Data layer, deployed apart from both charts (02). Start versions = what chart 1.5.41 bundles.
CH_START=25.2.1.3085             # clickhouse/clickhouse-server; chart 1.5.41 bundles bitnami/clickhouse:25.2.1-debian-12-r0
CH_TARGET=26.8.39.19             # newest 26.8 LTS patch on Docker Hub (2026-11-17)
PG_MAIN=17.3                     # postgres; chart 1.5.41 bundles bitnami/postgresql 17.3.0
PG_NEW=17.12                     # option (a): a new instance, newest 17.x
VALKEY=8.0.2                     # valkey/valkey; chart 1.5.41 bundles bitnami/valkey 8.0.2
MINIO_IMAGE=docker.io/bitnamilegacy/minio:2024.12.18-debian-12-r1   # chart 1.5.41's MinIO; ships `mc`

CH_PW=clickhouse-lab; PG_PW=postgres-lab; REDIS_PW=redis-lab
S3_USER=langfuse; S3_PW=minio-lab-password; BUCKET=langfuse

# Headless init (LANGFUSE_INIT_*): lab values only; the cluster is local.
LF_PK=pk-lf-sbs-lab
LF_SK=sk-lf-sbs-lab
LF_USER=admin@example.com
LF_PASSWORD=sbs-lab-password
LF_PROJECT=sbs-lab

kx() { kubectl --context "$KCTX" "$@"; }
hx() { helm --kube-context "$KCTX" "$@"; }
log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1: $2"; else echo "FAIL  $1: expected $3, got $2"; fail=1; fi; }
now() { python3 -c 'import time; print(f"{time.time():.1f}")'; }
elapsed() { python3 -c "print(f'{$(now) - $1:.1f}')"; }

# Local port for a Service, via a port-forward this step owns. Prints the URL.
pf() {
  local name=$1 svc=$2 port=$3 local_port
  local_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1])')
  kx -n "$NS" port-forward "svc/$svc" "$local_port:$port" >"$WORK/pf-$name.log" 2>&1 &
  echo $! >"$WORK/pf-$name.pid"
  for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$local_port" && break; sleep 1; done
  echo "http://127.0.0.1:$local_port"
}
pf_stop() { [ -f "$WORK/pf-$1.pid" ] && kill "$(cat "$WORK/pf-$1.pid")" 2>/dev/null; rm -f "$WORK/pf-$1.pid"; }

# Stores. ch runs clickhouse-client in the ClickHouse pod; psql takes the database as $1.
ch() { kx -n "$NS" exec -i clickhouse-0 -- clickhouse-client --password "$CH_PW" "$@"; }
psql_() { local db=$1; shift; kx -n "$NS" exec -i pg-main-0 -- env PGPASSWORD="$PG_PW" psql -U postgres -d "$db" -tAX "$@"; }
psql_new() { local db=$1; shift; kx -n "$NS" exec -i pg-new-0 -- env PGPASSWORD="$PG_PW" psql -U postgres -d "$db" -tAX "$@"; }
rcli() { kx -n "$NS" exec -i valkey-0 -- valkey-cli -a "$REDIS_PW" --no-auth-warning "$@"; }

PYTHON=${PYTHON:-python3.12}
PY="$WORK/venv-v3/bin/python"    # SDK v3 (the producers of the v3 deployment)
PY4="$WORK/venv-v4/bin/python"   # SDK v4

# HTTP status of a public API call: api <url> GET /api/public/traces
api() { curl -s -o /dev/null -w '%{http_code}' -u "$LF_PK:$LF_SK" -X "$2" "$1$3" ${4:+-H 'Content-Type: application/json' -d "$4"}; }
apij() { curl -s -u "$LF_PK:$LF_SK" "$1$2"; }

# Helm values: a release's values file plus the generated per-run overrides.
v3_install() { hx upgrade --install "$V3" "$CHART" --version "$CHART_V1" -n "$NS" -f "$LAB_DIR/values/v3.yaml" \
  --set langfuse.image.tag="$LF_V3" "$@" --wait --timeout 15m; }
v4_install() { hx upgrade --install "$V4" "$CHART" --version "$CHART_V2" -n "$NS" -f "$LAB_DIR/values/v4.yaml" \
  --set langfuse.image.tag="$LF_V4" "$@" --wait --timeout 20m; }
# Restart web, then worker (the worker looks for background migrations once, at start).
restart() {
  kx -n "$NS" rollout restart deploy/"$1"-langfuse-web >/dev/null; kx -n "$NS" rollout status deploy/"$1"-langfuse-web --timeout=900s >/dev/null
  kx -n "$NS" rollout restart deploy/"$1"-langfuse-worker >/dev/null; kx -n "$NS" rollout status deploy/"$1"-langfuse-worker --timeout=900s >/dev/null
}
# v4 environment overrides live in a ConfigMap (envFrom), so a change is apply + restart.
v4env() {  # v4env KEY=VALUE ... (merged into the ConfigMap lf-v4-env)
  local cur; cur=$(kx -n "$NS" get configmap lf-v4-env -o json 2>/dev/null | jq -r '.data // {} | to_entries[] | "\(.key)=\(.value)"' || true)
  printf '%s\n' "$cur" "$@" | grep -v '^$' | awk -F= '{a[$1]=$0} END {for (k in a) print a[k]}' >"$WORK/v4env.env"
  kx -n "$NS" create configmap lf-v4-env --from-env-file="$WORK/v4env.env" --dry-run=client -o yaml | kx apply -f - >/dev/null
}
