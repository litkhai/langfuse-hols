#!/usr/bin/env bash
# inventory.sh v1|v2 — row and object counts of one release's stores, one `key value` per line.
# Compared before and after the chart migration (05), and read again in the v4 steps.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
side=${1:?v1 or v2}
psql_() { if [ "$side" = v1 ]; then v1_psql "$@"; else v2_psql "$@"; fi; }
ch_()   { if [ "$side" = v1 ]; then v1_ch "$@"; else v2_ch "$@"; fi; }

for t in users organizations projects api_keys prompts datasets dataset_items dataset_runs \
         score_configs llm_api_keys audit_logs background_migrations; do
  printf 'pg.%s %s\n' "$t" "$(psql_ -c "SELECT count(*) FROM $t" 2>/dev/null || echo -)"
done
# API keys are stored hashed with the salt; the hash must survive the copy unchanged.
printf 'pg.api_key_hash %s\n' "$(psql_ -c "SELECT md5(string_agg(hashed_secret_key, ',' ORDER BY id)) FROM api_keys")"

for t in traces observations scores dataset_run_items_rmt blob_storage_file_log events_full events_core; do
  printf 'ch.%s %s\n' "$t" "$(ch_ -q "SELECT count() FROM $t FINAL" 2>/dev/null || echo -)"
done

mc_pod=lab-mc
if ! kx -n "$NS" get pod "$mc_pod" >/dev/null 2>&1; then
  kx -n "$NS" run "$mc_pod" --restart=Never --image="$MC_IMAGE" --command -- sleep 86400 >/dev/null
  kx -n "$NS" wait --for=condition=Ready "pod/$mc_pod" --timeout=120s >/dev/null
fi
if [ "$side" = v1 ]; then
  key=$(kx -n "$NS" get secret "$V1-s3" -o jsonpath='{.data.root-user}' | base64 -d)
  sec=$(kx -n "$NS" get secret "$V1-s3" -o jsonpath='{.data.root-password}' | base64 -d)
  ep=http://$V1-s3:9000
else
  key=$(kx -n "$NS" get secret "$V2-s3-auth" -o jsonpath='{.data.accessKey}' | base64 -d)
  sec=$(kx -n "$NS" get secret "$V2-s3-auth" -o jsonpath='{.data.secretKey}' | base64 -d)
  ep=http://$V2-s3-all-in-one:8333
fi
kx -n "$NS" exec "$mc_pod" -- mc alias set "$side" "$ep" "$key" "$sec" >/dev/null
printf 's3.objects %s\n' "$(kx -n "$NS" exec "$mc_pod" -- sh -c "mc ls --recursive $side/langfuse 2>/dev/null | wc -l" | tr -d ' ')"
