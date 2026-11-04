#!/usr/bin/env bash
# 99-down.sh — delete the kind cluster (everything in it, the generated Secrets included).
set -euo pipefail
kind delete cluster --name langfuse-k8s
