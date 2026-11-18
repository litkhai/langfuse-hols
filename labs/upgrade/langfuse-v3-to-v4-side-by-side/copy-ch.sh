#!/usr/bin/env bash
# copy-ch.sh initial|delta — copy v3's ClickHouse rows (database default) into the v4 database
# (langfuse_v4) with INSERT … SELECT on the same cluster. Columns are the intersection of the two
# schemas (v4 adds columns with defaults; MATERIALIZED/ALIAS columns are computed by the target).
#   initial  rows with event_ts <= now, and that watermark is saved to .work/watermark
#   delta    rows with event_ts > the saved watermark (a new watermark is saved)
# DateTime64 values that v3 < 3.225.7 wrote to ClickHouse >= 26.8 without
# input_format_read_datetime_number_as_raw_value=1 are 1000x too large (shown as 9999-12-31; 05).
# The copy repairs them: a value after 2200-01-01 is divided by 1000. Writes one line per table:
# <table> <rows copied> <rows repaired> <seconds>.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
mode=${1:?initial or delta}
# traces/observations/scores: the read tables; dataset_run_items_rmt: experiments (backfill step 4);
# blob_storage_file_log: the event files, so a deletion on v4 also removes v3-era files.
TABLES=${TABLES:-traces observations scores dataset_run_items_rmt blob_storage_file_log}
fix() { echo "if($1 > toDateTime64('2200-01-01', 3), fromUnixTimestamp64Milli(intDiv(toUnixTimestamp64Milli($1), 1000)), $1)"; }
sel_col() { if [[ ",$2," == *",$1,"* ]]; then echo "$(fix "$1") AS $1"; else echo "$1"; fi; }
ets=$(fix event_ts)
new_wm=$(ch -q "SELECT toString(now64(3))")
case $mode in
  initial) where="$ets <= '$new_wm'" ;;
  delta)   where="$ets > '$(cat "$WORK/watermark")' AND $ets <= '$new_wm'" ;;
esac
for t in $TABLES; do
  cols=$(ch -q "SELECT arrayStringConcat(groupArray(name), ',') FROM (
      SELECT name FROM system.columns WHERE database = 'langfuse_v4' AND table = '$t'
        AND default_kind NOT IN ('MATERIALIZED', 'ALIAS', 'EPHEMERAL')
        AND name IN (SELECT name FROM system.columns WHERE database = 'default' AND table = '$t')
      ORDER BY position)")
  dt=$(ch -q "SELECT arrayStringConcat(groupArray(name), ',') FROM system.columns WHERE database = 'default' AND table = '$t' AND type LIKE '%DateTime64(3%'")
  sel=$(for c in ${cols//,/ }; do sel_col "$c" "$dt"; done | paste -sd, -)
  bad=$(for c in ${dt//,/ }; do echo "$c > toDateTime64('2200-01-01', 3)"; done | paste -sd'|' - | sed 's/|/ OR /g')
  t0=$(now)
  n=$(ch -q "SELECT count() FROM default.$t WHERE $where")
  r=$(ch -q "SELECT count() FROM default.$t WHERE ($where) AND (${bad:-0})")
  ch -q "INSERT INTO langfuse_v4.$t ($cols) SELECT $sel FROM default.$t WHERE $where"
  echo "$t $n $r $(elapsed "$t0")"
done
echo "$new_wm" >"$WORK/watermark"
echo "watermark $new_wm"
