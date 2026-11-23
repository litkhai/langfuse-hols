#!/usr/bin/env bash
# 99-drop.sh — drop lab_langfuse_ch_mv (its views stop reading default.events_full with it) and the
# scratch databases of 05 and 06. The Langfuse tables and this lab's traces in them are left alone.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
for db in "$LAB_DB" lab_langfuse_ch_mv_bench lab_langfuse_ch_mv_upgrade; do
  ch "DROP DATABASE IF EXISTS $db SYNC"
  echo "dropped $db"
done
