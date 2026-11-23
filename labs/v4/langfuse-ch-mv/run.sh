#!/usr/bin/env bash
# run.sh — the whole lab in order, from an empty lab database (the shared v4 stack must be up). Log: results/run.log.
#   02 before the views, 03 views + backfill, 04 check, 02 again (rows now arrive through the views), 04,
#   07 retry + delete (04 FAILs), 08 repair, 04, 05 benchmark, 06 upgrade test.
# 99-drop.sh is not run: the tables stay for queries; drop them when done.
set -euo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec > >(tee "$H/results/run.log") 2>&1
B1="${B1:-$(date -u +%m%d%H%M)a}"; B2="${B1%a}b"
step() { echo; echo "===== $* ($(date -u +%T) UTC)"; "$@"; }
step "$H/99-drop.sh"
step "$H/01-schema.sh"
step "$H/02-seed.sh" "$B1" 100
step "$H/03-mv.sh"
step "$H/04-check.sh"
step "$H/02-seed.sh" "$B2" 50
step "$H/04-check.sh"
step "$H/07-retry-delete.sh" || true
step "$H/08-repair.sh"
step "$H/04-check.sh"
step "$H/05-bench.sh" "${BENCH_MILLIONS:-6}"
step "$H/06-upgrade.sh"
echo; echo "===== done $(date -u +%T) UTC"
