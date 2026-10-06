#!/usr/bin/env bash
# 99-cleanup.sh — stop the stack. Pass --purge to also delete all volumes (Postgres,
# ClickHouse, Redis, MinIO data) for a clean slate.
#
# The stack is shared by every lab and lives in ../../../_base — this is a thin
# wrapper around _base/bin/down.sh v4 (see _base/README.md).
exec "$(dirname "${BASH_SOURCE[0]}")/../../../_base/bin/down.sh" v4 "$@"
