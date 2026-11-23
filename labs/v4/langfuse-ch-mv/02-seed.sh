#!/usr/bin/env bash
# 02-seed.sh <batch> [traces per service, default 100] — four services in parallel, then wait for ClickHouse.
#
# One 02-seed.py process per service, each with its own OTEL_SERVICE_NAME. Langfuse writes the spans to
# events_full through its worker (OTLP → blob storage → queue → ClickHouse), so the script waits until this
# batch's row count has not changed for 20 s, then prints it per service and type.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
BATCH="${1:?usage: 02-seed.sh <batch> [traces per service]}"; N="${2:-100}"
SERVICES=(support-chat doc-summary policy-qa voc-classify)

pids=()
for s in "${SERVICES[@]}"; do
  OTEL_SERVICE_NAME="$s" "$PY" "$HERE/02-seed.py" "$s" "$N" "$BATCH" & pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

COUNT="SELECT count() FROM default.events_full WHERE has(tags, '$LAB_TAG')
       AND metadata_values[indexOf(metadata_names, 'batch')] = '$BATCH'"
last=-1; same=0
for i in $(seq 1 90); do
  n=$(ch "$COUNT")
  if [[ "$n" == "$last" && "$n" -gt 0 ]]; then same=$((same+1)); else same=0; fi
  [[ $same -ge 4 ]] && break
  last=$n; sleep 5
done
echo "batch $BATCH: $n observations in events_full"
ch "SELECT service_name, type, count() AS observations, uniqExact(trace_id) AS traces
    FROM default.events_full
    WHERE has(tags, '$LAB_TAG') AND metadata_values[indexOf(metadata_names, 'batch')] = '$BATCH'
    GROUP BY service_name, type ORDER BY service_name, type" PrettyCompactMonoBlock
