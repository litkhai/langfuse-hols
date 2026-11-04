#!/usr/bin/env bash
# 03c-reconcile.sh — find raw OTLP files whose observations are missing in ClickHouse, and re-process them.
#
# Every OTLP POST is stored once in blob storage (events/otel/<project>/<yyyy>/<mm>/<dd>/<hh>/<mi>/<uuid>.json,
# web: OtelIngestionProcessor.publishToOtelIngestionQueue) and every events_full row keeps the file it came
# from (blob_storage_file_path). For each run of results/03-failures.jsonl this script lists the run's files in
# MinIO (the minutes the run covered), counts rows per file in events_full, and reports files with fewer rows
# than the run sent per POST (obs × traces_per_post) or with none. With --replay it puts those files back on the
# OTel ingestion queue with their full key (requeue-otel.js, run inside the worker container) and counts again.
# Not POST /api/admin/ingestion-replay: on 4.56.0 it rejects a full events/otel/… key ("Unsupported replay
# type: otel") and queues a prefix-relative key that the worker then cannot download (NoSuchKey) (README).
#   Usage: ./03c-reconcile.sh [--replay] [run_id ...]     (default: every run in results/03-failures.jsonl)
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REPLAY=0; [[ "${1:-}" == --replay ]] && { REPLAY=1; shift; }
runs=("$@"); [[ ${#runs[@]} -eq 0 ]] && while IFS= read -r r; do runs+=("$r"); done < <(jq -r .run_id "$RESULTS/03-failures.jsonl")
PROJ="${LANGFUSE_INIT_PROJECT_ID:?}"
mcx() { docker exec "$LF_PROJECT-minio-1" sh -c "mc alias set lab http://localhost:9000 '${MINIO_ROOT_USER:-minio}' '${MINIO_ROOT_PASSWORD:-miniosecret}' >/dev/null 2>&1; $1"; }

for run in "${runs[@]}"; do
  lg=$(jq -c --arg r "$run" 'select(.run_id == $r)' "$RESULTS/03-failures.jsonl")
  per=$(jq -r '.obs * .traces_per_post' <<<"$lg")
  t0=$(jq -r '.started_unix | floor' <<<"$lg"); t1=$(jq -r '(.started_unix + .wall_s + 60) | floor' <<<"$lg")
  keys="$(mktemp)"
  for ((m = t0 / 60 * 60; m <= t1; m += 60)); do
    p="events/otel/$PROJ/$(date -u -r "$m" '+%Y/%m/%d/%H/%M' 2>/dev/null || date -u -d "@$m" '+%Y/%m/%d/%H/%M')/"
    mcx "mc ls --recursive lab/langfuse/$p 2>/dev/null" | awk -v p="$p" '{print p $NF}' >> "$keys"
  done
  rows="$(mktemp)"
  ch "SELECT blob_storage_file_path, uniqExact(span_id) FROM events_full
      WHERE blob_storage_file_path LIKE 'events/otel/$PROJ/%' AND has(tags, '$run') GROUP BY 1 FORMAT TSV" > "$rows"
  # files of this run = files with rows of this run + files with no rows at all in the run's minutes
  ch "SELECT DISTINCT blob_storage_file_path FROM events_full WHERE blob_storage_file_path LIKE 'events/otel/$PROJ/%'
      AND created_at >= fromUnixTimestamp($t0) - INTERVAL 1 MINUTE AND NOT has(tags, '$run') FORMAT TSV" > "$rows.other"
  bad=$(awk -F'\t' -v per="$per" 'FNR == NR && FILENAME ~ /other$/ {o[$1] = 1; next}
         FILENAME !~ /other$/ && NF == 2 {n[$1] = $2; next}
         {k = $1; if (k in o) next; if (!(k in n)) print k "\t0"; else if (n[k] < per) print k "\t" n[k]}' \
         "$rows.other" "$rows" "$keys")
  nfiles=$(wc -l < "$keys" | tr -d ' ')
  nbad=$(grep -c . <<<"$bad" || true)
  echo "$run: $nfiles files in blob storage, $(wc -l < "$rows" | tr -d ' ') with rows, $nbad short (rows < $per):"
  [[ -n "$bad" ]] && sed 's/^/    /' <<<"$bad"
  if [[ $REPLAY == 1 && -n "$bad" ]]; then
    # shellcheck disable=SC2046
    echo "  requeue: $(docker exec -i "$LF_PROJECT-langfuse-worker-1" sh -c 'cd /app/worker && node - "$@"' _ "$PROJ" \
          $(cut -f1 <<<"$bad") < "$HERE/requeue-otel.js" 2>/dev/null | tail -1)"
    sleep 30
    echo "  after requeue: $(ch "SELECT uniqExact(span_id) FROM events_full WHERE has(tags, '$run')") distinct observations of $(jq -r .accepted_obs <<<"$lg") accepted"
  fi
  rm -f "$keys" "$rows" "$rows.other"
done
