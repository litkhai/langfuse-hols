#!/usr/bin/env bash
# 09-captures.sh [names] — run 09-captures.mjs with the environment of lib.sh (default: all five captures).
# For "upgrade" it first builds lab_langfuse_ch_mv_upgrade.probe (a copy of events_full's DDL with the
# per-service view of 03 attached) and renames provided_model_name, then drops that database again.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export LANGFUSE_INIT_USER_EMAIL LANGFUSE_INIT_USER_PASSWORD LANGFUSE_INIT_PROJECT_ID CLICKHOUSE_USER CLICKHOUSE_PASSWORD
names=("${@:-traces rollup review bench upgrade}"); names=(${names[@]})
U=lab_langfuse_ch_mv_upgrade
if [[ " ${names[*]} " == *" upgrade "* ]]; then
  ch "DROP DATABASE IF EXISTS $U SYNC"; ch "CREATE DATABASE $U"
  ch "CREATE TABLE $U.probe AS default.events_full"
  ch "CREATE TABLE $U.probe__obs_hourly_by_service AS $LAB_DB.obs_hourly_by_service"
  ch "CREATE MATERIALIZED VIEW $U.probe__obs_hourly_by_service_mv TO $U.probe__obs_hourly_by_service AS $(view_select obs_hourly_by_service 1 "$U.probe")"
  ch "ALTER TABLE $U.probe RENAME COLUMN provided_model_name TO model_name"
fi
node "$HERE/09-captures.mjs" "${names[@]}"
if [[ " ${names[*]} " == *" upgrade "* ]]; then
  echo "probe rows written although the INSERT failed: $(ch "SELECT count() FROM $U.probe")"
  ch "DROP DATABASE $U SYNC"
fi
