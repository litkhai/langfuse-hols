#!/usr/bin/env bash
# 04 — data on v3: SDK v3 traces with scores, legacy-API traces, prompts, a dataset and an
# experiment run, one media attachment, one LLM connection (encrypted key). Then the
# background-migration state that v4 depends on.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
phase=${1:-v3-start}
url=$(pf app langfuse-app 3000); trap 'pf_stop app' EXIT
export LANGFUSE_HOST=$url LANGFUSE_PUBLIC_KEY=$LF_PK LANGFUSE_SECRET_KEY=$LF_SK
curl -s "$url/api/public/health"; echo

if [ "$phase" = v3-start ]; then
  "$PY" produce.py setup
  "$PY" produce.py llm-connection

  log "media: one PNG attached to a trace's input (POST /api/public/media, PUT to S3 in-cluster, PATCH)"
  png=$(printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==')
  echo "$png" | base64 -d >"$WORK/media.png"
  sha=$(openssl dgst -sha256 -binary "$WORK/media.png" | base64); len=$(wc -c <"$WORK/media.png" | tr -d ' ')
  tid=media-trace-$(date +%s)
  resp=$(curl -s -u "$LF_PK:$LF_SK" -H 'Content-Type: application/json' -X POST "$url/api/public/media" \
    -d "{\"traceId\":\"$tid\",\"contentType\":\"image/png\",\"contentLength\":$len,\"sha256Hash\":\"$sha\",\"field\":\"input\"}")
  echo "$resp" | jq -c '{mediaId, uploadUrl: (.uploadUrl|tostring|.[0:60])}'
  mid=$(echo "$resp" | jq -r .mediaId); up=$(echo "$resp" | jq -r .uploadUrl)
  kx -n "$NS" cp "$WORK/media.png" lab-curl:/tmp/media.png
  code=$(kx -n "$NS" exec lab-curl -- curl -s -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: image/png' \
    -H "x-amz-checksum-sha256: $sha" --data-binary @/tmp/media.png "$up")
  echo "PUT to S3: $code"
  curl -s -o /dev/null -w 'PATCH media: %{http_code}\n' -u "$LF_PK:$LF_SK" -H 'Content-Type: application/json' -X PATCH \
    "$url/api/public/media/$mid" -d "{\"uploadedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"uploadHttpStatus\":$code}"
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  curl -s -u "$LF_PK:$LF_SK" -H 'Content-Type: application/json' -X POST "$url/api/public/ingestion" \
    -d "{\"batch\":[{\"id\":\"$tid-e\",\"type\":\"trace-create\",\"timestamp\":\"$ts\",\"body\":{\"id\":\"$tid\",\"name\":\"media-trace\",\"tags\":[\"phase:$phase\",\"media\"],\"input\":{\"image\":\"@@@langfuseMedia:type=image/png|id=$mid|source=bytes@@@\"}}}]}" | jq -c .
  printf '{"phase":"%s","producer":"media","trace_id":"%s","media_id":"%s","sha256":"%s"}\n' "$phase" "$tid" "$mid" "$sha" >>"$WORK/sent.jsonl"
fi

"$PY" produce.py traces --phase "$phase" --n 40
"$PY" produce.py legacy-http --phase "$phase" --n 10
sleep 20   # worker: S3 event file -> ClickHouse

log "background migrations on $LF_V3 (wait until none is unfinished)"
for _ in $(seq 1 60); do [ "$(psql_ langfuse -c "SELECT count(*) FROM background_migrations WHERE finished_at IS NULL")" = 0 ] && break; sleep 10; done
psql_ langfuse -c "SELECT name, finished_at IS NOT NULL AS finished, failed_at IS NOT NULL AS failed FROM background_migrations ORDER BY name"
./inventory.sh langfuse default | tee "$WORK/inventory-v3-$phase.txt"
