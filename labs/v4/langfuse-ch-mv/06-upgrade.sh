#!/usr/bin/env bash
# 06-upgrade.sh — what a Langfuse ClickHouse migration does to these views, measured on copies of events_full.
#
# Part 1, the real migrations. Lists the ClickHouse migrations of two Langfuse images (FROM = the stack's
# version, TO = LF_TO, default 4.83.0; both images must be local: docker pull langfuse/langfuse:<TO>) and
# prints the new ones that touch events_full. Then, on lab_langfuse_ch_mv_upgrade.events_full (CREATE TABLE …
# AS default.events_full) with the three views of 03 and one "SELECT *" copy view attached, applies the
# events_full statements of those migrations as they ship in the TO image (table name prefixed), inserts this
# lab's rows, and compares each view's table with the rows.
#
# Part 2, changes no Langfuse migration has made to events_full so far (4.83.0), on a fresh copy each: rename,
# drop and change the type of a column the views read. For each: does the ALTER succeed, does the next
# INSERT into the source table succeed (Langfuse's ingestion is that insert), what reached the source and the
# views' tables, then the same INSERT with materialized_views_ignore_errors = 1.
# Langfuse's tables are only read. Output: results/06-upgrade.txt.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
U=lab_langfuse_ch_mv_upgrade
FROM="$(. "$TRACK_DIR/versions.env"; echo "$LANGFUSE_VERSION")"; TO="${LF_TO:-4.83.0}"
OUT="$RESULTS/06-upgrade.txt"
exec > >(tee "$OUT") 2>&1
echo "# 06-upgrade.sh, $(date -u +%FT%TZ), ClickHouse $(ch 'SELECT version()'), Langfuse $FROM -> $TO"

MIG="$RESULTS/.migrations"; rm -rf "$MIG"; mkdir -p "$MIG"
for v in "$FROM" "$TO"; do
  c=$(docker create "langfuse/langfuse:$v") || { echo "✗ image langfuse/langfuse:$v not local: docker pull it"; exit 1; }
  docker cp -q "$c:/app/packages/shared/clickhouse/migrations/unclustered" "$MIG/$v"; docker rm "$c" > /dev/null
done
echo; echo "## Migrations in $TO that $FROM does not have"
new=$(comm -13 <(ls "$MIG/$FROM" | grep '\.up\.sql$') <(ls "$MIG/$TO" | grep '\.up\.sql$'))
for f in $new; do
  echo "$f: $(grep -ohE '(ALTER TABLE|CREATE TABLE( IF NOT EXISTS)?) [a-z_]+' "$MIG/$TO/$f" | awk '{print $NF}' | sort -u | tr '\n' ' ')"
done
echo "Shipped migrations whose text changed between the two images (already applied ones are not re-run):"
for f in $(ls "$MIG/$FROM" | grep '\.up\.sql$'); do cmp -s "$MIG/$FROM/$f" "$MIG/$TO/$f" || echo "  $f"; done

# fresh <table>: copy of events_full's DDL with the three views and a SELECT * copy view attached
fresh() {
  local s="$U.$1" t
  ch "CREATE TABLE $s AS default.events_full"
  for t in obs_hourly_by_service obs_hourly_by_tag review_observations; do
    ch "CREATE TABLE ${s}__$t AS $LAB_DB.$t"
    ch "CREATE MATERIALIZED VIEW ${s}__${t}_mv TO ${s}__$t AS $(view_select "$t" 1 "$s")"
  done
  ch "CREATE TABLE ${s}__star AS default.events_full"
  ch "CREATE MATERIALIZED VIEW ${s}__star_mv TO ${s}__star AS SELECT * FROM $s WHERE has(tags, '$LAB_TAG')"
}
# load <table>: insert this lab's rows (the columns default.events_full has) into the copy
SRC_COLS=$(target_columns default events_full)
load() { ch "INSERT INTO $U.$1 ($SRC_COLS) SELECT $SRC_COLS FROM default.events_full FINAL WHERE has(tags, '$LAB_TAG') AND is_deleted = 0"; }
report() {   # report <table>: rows in the source and in each view's table
  ch "SELECT
      (SELECT count() FROM $U.$1) AS source_rows,
      (SELECT sum(observations) FROM $U.$1__obs_hourly_by_service) AS by_service_observations,
      (SELECT sum(observations) FROM $U.$1__obs_hourly_by_tag WHERE tag LIKE 'svc:%') AS by_tag_observations,
      (SELECT count() FROM $U.$1__review_observations) AS review_rows,
      (SELECT count() FROM $U.$1__star) AS star_rows" PrettyCompactMonoBlock
}
try() {   # try <label> <sql>: run, print OK or the error's first line
  local err
  if err=$(ch "$2" 2>&1 >/dev/null); then echo "  $1: OK"; else echo "  $1: ERROR ${err%%$'\n'*}" | cut -c1-260; fi
}

ch "DROP DATABASE IF EXISTS $U SYNC"; ch "CREATE DATABASE $U"
echo; echo "## Part 1: the events_full statements of the new migrations, applied to a copy with the views attached"
fresh ev
load ev; echo "before the migrations (one load of this lab's rows):"; report ev
for f in $new; do
  # Statements end with ";" at the end of a line. Keep those on events_full; prefix the table name.
  awk 'BEGIN{RS=";[ \t]*\n"} /ALTER TABLE events_full/ {print $0 ";"}' "$MIG/$TO/$f" > "$MIG/$f.events_full"
  [[ -s "$MIG/$f.events_full" ]] || continue
  while IFS= read -r -d $'\x1e' stmt; do
    stmt="${stmt/ALTER TABLE events_full/ALTER TABLE $U.ev}"
    try "$f: $(echo "$stmt" | grep -oE '(ADD|MODIFY|DROP|RENAME) (COLUMN|INDEX)( IF NOT EXISTS| IF EXISTS)? [a-z_]+' | tr '\n' ',' | sed 's/,$//')" "$stmt"
  done < <(awk 'BEGIN{RS=";\n"; ORS="\x1e"} NF {print $0}' "$MIG/$f.events_full")
done
echo "columns of the copy now: $(ch "SELECT count() FROM system.columns WHERE database = '$U' AND table = 'ev'") (default.events_full: $(ch "SELECT count() FROM system.columns WHERE database = 'default' AND table = 'events_full'"))"
echo "insert after the migrations (a second load of the same rows):"
try "INSERT INTO ev" "INSERT INTO $U.ev ($SRC_COLS) SELECT $SRC_COLS FROM default.events_full FINAL WHERE has(tags, '$LAB_TAG') AND is_deleted = 0"
report ev
echo "SELECT * view, stored query: $(ch "SELECT as_select FROM system.tables WHERE database = '$U' AND name = 'ev__star_mv'" TSVRaw)"
echo "columns of its target: $(ch "SELECT count() FROM system.columns WHERE database = '$U' AND table = 'ev__star'")"

echo; echo "## Part 2: changes the views would not survive (none of them is in a Langfuse migration up to $TO)"
n=0
for change in "RENAME COLUMN provided_model_name TO model_name" "DROP COLUMN service_name" \
              "MODIFY COLUMN tags String" "ADD COLUMN lab_probe String DEFAULT ''"; do
  n=$((n+1)); t="c$n"
  fresh "$t"
  echo "### ALTER TABLE … $change"
  try "ALTER" "ALTER TABLE $U.$t $change"
  if [[ "$change" == "DROP COLUMN service_name" || "$change" == RENAME* || "$change" == MODIFY* ]]; then
    cols=$(ch "SELECT arrayStringConcat(groupArray(name), ', ') FROM (SELECT name FROM system.columns WHERE database = '$U' AND table = '$t' AND default_kind = '' ORDER BY position)")
    sel=$(ch "SELECT arrayStringConcat(groupArray(if(name = 'model_name', 'provided_model_name AS model_name', if(name = 'tags' AND type = 'String', 'toString(tags) AS tags', name))), ', ') FROM (SELECT name, type FROM system.columns WHERE database = '$U' AND table = '$t' AND default_kind = '' ORDER BY position)")
  else
    cols="$SRC_COLS"; sel="$SRC_COLS"
  fi
  q="INSERT INTO $U.$t ($cols) SELECT $sel FROM (SELECT * FROM default.events_full FINAL WHERE has(tags, '$LAB_TAG') AND is_deleted = 0)"
  try "INSERT (a Langfuse write)" "$q"; report "$t"
  try "INSERT with materialized_views_ignore_errors = 1" "${q/ SELECT / SETTINGS materialized_views_ignore_errors = 1 SELECT }"
  report "$t"
done
ch "DROP DATABASE IF EXISTS $U SYNC"
echo "dropped $U"
