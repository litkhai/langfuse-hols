#!/usr/bin/env bash
# 03-mv.sh — create lab_langfuse_ch_mv (tables + materialized views of 03-mv.sql), then backfill.
#
# A materialized view only sees rows inserted after it exists. The views keep rows with
# created_at >= CUTOFF (20 s from now); once CUTOFF has passed and Langfuse's worker has had 20 s more to
# write anything still in flight, each view's own SELECT with "created_at < CUTOFF" fills its target
# with the older rows. The backfill SELECT is read from system.tables (as_select), so it is the view's query
# (lib.sh view_insert).
# Refuses to run if the database already exists: 99-drop.sh first.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "$(ch "SELECT count() FROM system.databases WHERE name = '$LAB_DB'")" != 0 ]]; then
  echo "✗ $LAB_DB exists: run 99-drop.sh first (this lab starts from an empty database)" >&2; exit 1
fi
CUTOFF=$(ch "SELECT toString(toStartOfSecond(now64(6)) + INTERVAL 20 SECOND)")
echo "cutoff: $CUTOFF (server time zone $(ch "SELECT timezone()"))"
sed "s/{CUTOFF}/$CUTOFF/g" "$HERE/03-mv.sql" > "$RESULTS/.03-mv.rendered.sql"
chf "$RESULTS/.03-mv.rendered.sql"
echo "$CUTOFF" > "$RESULTS/.cutoff"

until [[ "$(ch "SELECT now64(6) > toDateTime64('$CUTOFF', 6) + INTERVAL 20 SECOND")" == 1 ]]; do sleep 2; done
# The backfill reads events_full FINAL: a row Langfuse wrote twice and has not merged yet counts once.
# (The view itself cannot: it sees each insert block on its own. 07 shows what that means.)
for t in obs_hourly_by_service obs_hourly_by_tag review_observations; do
  view_insert "$t" "created_at < toDateTime64('$CUTOFF', 6)"
  echo "backfilled $t: $(ch "SELECT count() FROM $LAB_DB.$t") rows"
done
ch "SELECT name, engine, total_rows FROM system.tables WHERE database = '$LAB_DB' ORDER BY name" PrettyCompactMonoBlock
