#!/usr/bin/env bash
# 03 — data on the old v3: SDK v3 traces, legacy-API traces, prompts, a dataset and an experiment run.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
phase=${1:-v3-start}

# The Service clients use. The lab owns it, so "shifting traffic" in 05 is one selector patch:
# the chart-without-Ingress case of the upstream guide.
kx -n "$NS" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata: {name: langfuse-app}
spec:
  selector: {app.kubernetes.io/instance: $V1, app: web}
  ports: [{port: 3000, targetPort: 3000}]
YAML

url=$(pf app langfuse-app 3000); trap 'pf_stop app' EXIT
export LANGFUSE_HOST=$url LANGFUSE_PUBLIC_KEY=$LF_PK LANGFUSE_SECRET_KEY=$LF_SK
curl -s "$url/api/public/health"; echo
[ "$phase" = v3-start ] && "$PY" produce.py setup
"$PY" produce.py traces --phase "$phase" --n 40
"$PY" produce.py legacy-http --phase "$phase" --n 10
sleep 20   # worker: S3 event file -> ClickHouse
./inventory.sh v1 | tee "$WORK/inventory-$phase.txt"
