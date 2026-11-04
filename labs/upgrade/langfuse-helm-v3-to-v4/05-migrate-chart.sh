#!/usr/bin/env bash
# 05 — chart v1 -> v2 with the upstream sibling procedure, Langfuse stays on v3.
# Runs examples/upgrade-v1-to-v2/scripts/migrate-v1-to-v2.sh at a pinned commit while traffic.sh
# writes one trace per second, retargets the client Service when the script asks for it, and
# compares the stores of both releases afterwards.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh

[ -d "$WORK/langfuse-k8s" ] || git clone -q "$K8S_REPO" "$WORK/langfuse-k8s"
git -C "$WORK/langfuse-k8s" fetch -q origin "$K8S_SHA" 2>/dev/null || true
git -C "$WORK/langfuse-k8s" checkout -q "$K8S_SHA"
scripts="$WORK/langfuse-k8s/examples/upgrade-v1-to-v2/scripts"

./inventory.sh v1 >"$WORK/inventory-v1-before.txt"
./traffic.sh start

log "upstream migrate-v1-to-v2.sh --yes (log: $WORK/05-migrate.log)"
# --image-tag: the script takes the tag from the values file or from the chart appVersion
# (3.224.1), not from the running pods. v1 runs $LF_V3 (set with --set in 04), so pass it.
# MC_IMAGE: the default quay.io/minio/mc:latest is not pullable (lib.sh).
# --force: the freeze waits for the v1 BullMQ queues to drain and counts the :delayed sets. Every
# v3 worker keeps one repeatable-job entry there per scheduler (integrations, data retention), so
# the depth never reaches 0 and the script stops with v1 web already at 0 (seen 2026-11-03: depth
# 4). check_queues prints wait+active (the real work) at the shift: it must be 0.
# Note that --force also skips the Postgres-lag and v2-readiness checks: 06 verifies both.
start=$(date +%s)
( cd "$scripts" && MC_IMAGE="$MC_IMAGE" ./migrate-v1-to-v2.sh --yes \
    --context "$KCTX" --namespace "$NS" --values "$LAB_DIR/v1-values.yaml" \
    --chart "$CHART" --chart-version "$CHART_V2" --image-tag "$LF_V3" --force \
    --extra-values "$LAB_DIR/v2-kind-values.yaml" \
    --output-values "$WORK/v2-values.generated.yaml" \
    --output-cutover-values "$WORK/v2-cutover-values.generated.yaml" ) \
  >"$WORK/05-migrate.log" 2>&1 &
mig=$!

check_queues() {  # the jobs that are real work: wait + active, without the :delayed repeat entries
  kx -n "$NS" exec "$V1-redis-primary-0" -- sh -c 'export REDISCLI_AUTH=redis-lab; t=0
    for k in $(valkey-cli --scan --pattern "bull:*:wait") $(valkey-cli --scan --pattern "bull:*:active"); do
      t=$((t + $(valkey-cli LLEN "$k"))); done; echo "$t"'
}

# The script prints this when it has scaled v2 up and wants traffic moved (no chart Ingress).
until grep -q "Point traffic at the new Service" "$WORK/05-migrate.log" 2>/dev/null; do
  kill -0 $mig 2>/dev/null || { tail -40 "$WORK/05-migrate.log"; die "migration script exited early"; }
  sleep 2
done
echo "v1 queues wait+active at the shift: $(check_queues)"
log "shift traffic: Service langfuse-app -> $V2 web pods ($(date +%s))"
kx -n "$NS" patch svc langfuse-app -p "{\"spec\":{\"selector\":{\"app.kubernetes.io/instance\":\"$V2\",\"app\":\"web\"}}}"
wait $mig
end=$(date +%s)
sleep 30
./traffic.sh stop
grep -E '^==>|^warning|^error' "$WORK/05-migrate.log" | sed "s/$(printf '\033')\[[0-9;]*m//g"
echo "script wall time: $((end - start))s"
./traffic.sh report
