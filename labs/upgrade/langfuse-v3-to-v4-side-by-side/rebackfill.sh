#!/usr/bin/env bash
# rebackfill.sh [yyyymm ...] — run v4's historic backfill (steps 1-4) again, so rows copied into
# langfuse_v4.traces/observations after its first run reach events_full. The rows are reset
# (finished_at, state) and, when partitions are given, args.partitions restricts the run to them
# (backfillBase honours it), and pollIntervalMs drops from 30 s to 2 s. The tables are ReplacingMergeTree, so a re-run is idempotent.
# A re-run writes every row of the partition again. events_full/events_core are ReplacingMergeTree,
# but v4's /api/public/v2/observations does not deduplicate, so until a merge each observation is
# listed twice (seen on the first run: 7 instead of 4). The touched partitions are therefore merged
# with OPTIMIZE … FINAL afterwards. Prints the seconds for each part.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
PGDB=${PGDB:-langfuse_v4}   # the Postgres database v4 runs on (10 moves it to langfuse_v4_cut)
chain="name LIKE '20260701_v4_step_%' AND name NOT LIKE '%step_5%'"
parts=$(printf '"%s",' "$@"); parts="[${parts%,}]"
[ $# -gt 0 ] && args="args || jsonb_build_object('partitions', '$parts'::jsonb, 'pollIntervalMs', 2000)" || args="(args - 'partitions') || '{\"pollIntervalMs\": 2000}'::jsonb"
psql_ "$PGDB" -c "UPDATE background_migrations SET finished_at = NULL, failed_at = NULL, failed_reason = NULL,
  locked_at = NULL, worker_id = NULL, state = '{}'::jsonb, args = $args WHERE $chain" >/dev/null
t0=$(now)
kx -n "$NS" rollout restart deploy/"$V4"-langfuse-worker >/dev/null
kx -n "$NS" rollout status deploy/"$V4"-langfuse-worker --timeout=600s >/dev/null
for _ in $(seq 1 360); do
  [ "$(psql_ "$PGDB" -c "SELECT count(*) FROM background_migrations WHERE $chain AND finished_at IS NULL AND failed_at IS NULL")" = 0 ] && break
  sleep 2
done
psql_ "$PGDB" -c "SELECT name, finished_at IS NOT NULL AS finished, failed_at IS NOT NULL AS failed, args->>'partitions' FROM background_migrations WHERE $chain ORDER BY name"
echo "rebackfill ${parts}: $(elapsed "$t0") s"
t0=$(now)
for p in "$@"; do for t in events_full events_core; do
  ch -q "OPTIMIZE TABLE langfuse_v4.$t ON CLUSTER default PARTITION ID '$p' FINAL" --format Null
done; done
echo "optimize final ${parts}: $(elapsed "$t0") s"
