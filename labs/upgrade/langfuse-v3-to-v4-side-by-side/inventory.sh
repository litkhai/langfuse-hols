#!/usr/bin/env bash
# inventory.sh <pg-db> <ch-db> — row counts of one release's stores, one `key value` per line.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
pgdb=${1:?postgres database}; chdb=${2:?clickhouse database}
for t in users organizations projects api_keys prompts datasets dataset_items dataset_runs \
         llm_api_keys media trace_media observation_media background_migrations; do
  printf 'pg.%s %s\n' "$t" "$(psql_ "$pgdb" -c "SELECT count(*) FROM $t" 2>/dev/null || echo -)"
done
for t in traces observations scores dataset_run_items_rmt blob_storage_file_log events_full events_core; do
  printf 'ch.%s %s\n' "$t" "$(ch -q "SELECT count() FROM $chdb.$t FINAL" 2>/dev/null || echo -)"
done
