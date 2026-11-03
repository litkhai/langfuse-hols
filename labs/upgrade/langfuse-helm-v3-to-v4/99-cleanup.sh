#!/usr/bin/env bash
# 99 — remove the kind cluster and the lab's generated files.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
kind delete cluster --name "$CLUSTER"
rm -rf "$WORK"
