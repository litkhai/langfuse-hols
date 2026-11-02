#!/usr/bin/env bash
# 17-ee-encryption.sh — encryption in transit and at rest for self-hosted Langfuse.
#
# Claims under test (each with a control that shows the check can see plaintext):
#   1. Langfuse → ClickHouse is TLS only: HTTPS answers with the lab CA, plain 8123 is
#      closed, and without the CA the certificate is rejected.
#   2. ClickHouse encrypted disk as the default MergeTree policy: Langfuse's tables land on
#      it, a trace written through Langfuse is readable through the API and absent from the
#      raw files; a CODEC(NONE) control table on the plain disk shows the same grep finds a
#      sentinel when it is there.
#   3. MinIO SSE-S3 requested by Langfuse (LANGFUSE_S3_*_SSE=AES256): the raw event object
#      is marked SSE and holds no plaintext; a control object without SSE does.
#   4. Application level: an LLM connection secret and the project's API secret key are not
#      in a full Postgres data dump; the plaintext public key and the connection name are.
# ClickHouse runs on its own volume (langfuse_clickhouse_encrypted_data) during this step; at
# the end the stack goes back to the plain overlay set and the original volume.
#
# Requires: EE active (run 05 first), `jq`, `openssl`, `curl`. Keys and certificates are made
# once under _base/encryption/{secrets,certs}/ (gitignored) and reused, because the encrypted
# volume can only be read with the same disk key.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4; load_env "$BASE_DIR/.env"
cd "$(dirname "$0")"

for c in jq openssl curl; do command -v "$c" >/dev/null || { echo "✗ please install $c"; exit 1; }; done
HOST="${NEXTAUTH_URL:-http://localhost:3000}"
AUTH="${LANGFUSE_PUBLIC_KEY:?set LANGFUSE_PUBLIC_KEY in _base/.env}:${LANGFUSE_SECRET_KEY:?set LANGFUSE_SECRET_KEY in _base/.env}"
PROJ="${LANGFUSE_INIT_PROJECT_ID:-llm-observability}"
TS=$(date +%Y%m%d%H%M%S)
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
CH_IMAGE="docker.io/clickhouse/clickhouse-server:${CLICKHOUSE_VERSION:-$(sed -n 's/^CLICKHOUSE_VERSION=//p' "$TRACK_DIR/versions.env")}"
CH_USER="${CLICKHOUSE_USER:-clickhouse}"; CH_PASS="${CLICKHOUSE_PASSWORD:-clickhouse}"

ROWS="$WORK/rows.tsv"; : > "$ROWS"; FAILS=0
# row <area> <check> <expected> <observed> <ok:0|1|info>
row() {
  local res=PASS
  if [ "$5" = info ]; then res=INFO; elif [ "$5" != 1 ]; then res=FAIL; FAILS=$((FAILS+1)); fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$res" >> "$ROWS"
  echo "  $res  $1 | $2 | expected: $3 | observed: $4"
}

wait_health() {
  for _ in $(seq 1 120); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$HOST/api/public/health")" = 200 ] && return 0; sleep 2
  done
  echo "✗ langfuse-web did not become healthy"; exit 1
}
# rawgrep <volume> <fixed string> [path inside the volume] → files holding it (read-only mount)
rawgrep() {
  docker run --rm -v "${LF_PROJECT}_$1:/v:ro" --entrypoint sh "$CH_IMAGE" \
    -c 'grep -rlF -- "$0" "/v/$1" 2>/dev/null | sed "s#^/v/##"' "$2" "${3:-}" || true
}
count() { grep -c . <<< "$1" || true; }

# send_trace <input text> → trace id; one OTLP root span whose input is the text
send_trace() {
  local tid; tid=$(openssl rand -hex 16); local nano; nano="$(date +%s)000000000"
  curl -fsS -m 30 -o /dev/null -u "$AUTH" -X POST "$HOST/api/public/otel/v1/traces" \
    -H "Content-Type: application/json" -H "x-langfuse-ingestion-version: 4" \
    -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"encryption-lab\"}}]},
         \"scopeSpans\":[{\"scope\":{\"name\":\"encryption-lab\"},\"spans\":[{\"traceId\":\"$tid\",
         \"spanId\":\"$(openssl rand -hex 8)\",\"name\":\"encryption-lab\",\"kind\":1,
         \"startTimeUnixNano\":\"$nano\",\"endTimeUnixNano\":\"$nano\",
         \"attributes\":[{\"key\":\"langfuse.observation.input\",\"value\":{\"stringValue\":\"$1\"}}]}]}]}]}"
  echo "$tid"
}
# api_input <trace id> → the input the public API returns (waits for async ingestion)
api_input() {
  local v=""
  for _ in $(seq 1 40); do
    v=$(curl -s -m 30 -u "$AUTH" "$HOST/api/public/v2/observations?traceId=$1&fields=core,io" |
      jq -r '.data[0].input // empty' 2>/dev/null || true)
    [ -n "$v" ] && break; sleep 3
  done
  echo "$v"
}

echo "════ 0. Keys and certificates (made once, reused) ════"
SEC="$BASE_DIR/encryption/secrets"; CRT="$BASE_DIR/encryption/certs"
mkdir -p "$SEC" "$CRT"; chmod 700 "$SEC"
[ -s "$SEC/clickhouse-disk.hex" ] || { openssl rand -hex 32 > "$SEC/clickhouse-disk.hex"; chmod 600 "$SEC/clickhouse-disk.hex"; }
[ -s "$SEC/minio-kms.key" ] || { echo "langfuse-lab-key:$(openssl rand -base64 32)" > "$SEC/minio-kms.key"; chmod 600 "$SEC/minio-kms.key"; }
if [ ! -s "$CRT/server.crt" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=langfuse-hols lab CA" \
    -keyout "$SEC/ca.key" -out "$CRT/ca.crt" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=clickhouse" -keyout "$CRT/server.key" -out "$WORK/server.csr" 2>/dev/null
  printf 'subjectAltName=DNS:clickhouse,DNS:localhost,IP:127.0.0.1\n' > "$WORK/san.ext"
  openssl x509 -req -in "$WORK/server.csr" -CA "$CRT/ca.crt" -CAkey "$SEC/ca.key" -CAcreateserial \
    -days 365 -extfile "$WORK/san.ext" -out "$CRT/server.crt" 2>/dev/null
  rm -f "$CRT/ca.srl"
fi
# The ClickHouse container runs as uid 101 and reads the key through a bind mount.
chmod 755 "$CRT"; chmod 644 "$CRT"/*
CLICKHOUSE_ENCRYPTION_KEY=$(cat "$SEC/clickhouse-disk.hex"); MINIO_KMS_SECRET_KEY=$(cat "$SEC/minio-kms.key")
export CLICKHOUSE_ENCRYPTION_KEY MINIO_KMS_SECRET_KEY
echo "  disk key, KMS key, CA and server certificate under _base/encryption/ (not printed)"

echo "════ 1. Restart with the encryption overlay (ClickHouse on its own volume) ════"
# --force-recreate: the bind-mounted config files may have changed without compose noticing.
lf_compose ee encryption -- up -d --force-recreate clickhouse minio langfuse-web langfuse-worker >/dev/null 2>&1
wait_health
chq() { lf_compose ee encryption -- exec -T clickhouse clickhouse-client --user "$CH_USER" --password "$CH_PASS" "$@"; }
webnode() { lf_compose ee encryption -- exec -T "$@"; }
FETCH='fetch(process.argv[1]).then(r=>r.text()).then(t=>console.log("ok "+t.trim())).catch(e=>console.log("error "+(e.cause&&e.cause.code||e.message)))'

echo "════ 2. In transit: Langfuse → ClickHouse ════"
o=$(webnode langfuse-web node -e "$FETCH" https://clickhouse:8443/ping)
[ "$o" = "ok Ok." ] && ok=1 || ok=0; row transit "HTTPS 8443 from langfuse-web, lab CA trusted" "ok Ok." "$o" $ok
o=$(webnode -e NODE_EXTRA_CA_CERTS= langfuse-web node -e "$FETCH" https://clickhouse:8443/ping)
case "$o" in error*CERT*|error*SIGNATURE*|error*ISSUER*) ok=1 ;; *) ok=0 ;; esac
row transit "HTTPS 8443 without the lab CA" "certificate error" "$o" $ok
o=$(webnode langfuse-web node -e "$FETCH" http://clickhouse:8123/ping)
case "$o" in error*) ok=1 ;; *) ok=0 ;; esac; row transit "plain HTTP 8123" "refused" "$o" $ok
o=$(chq -q "SELECT 'tls ok'" 2>&1 | tail -1); [ "$o" = "tls ok" ] && ok=1 || ok=0
row transit "clickhouse-client on 9440, strict certificate check" "tls ok" "$o" $ok
# From a second container on the compose network, like any other client would connect.
o=$(docker run --rm --network "${LF_PROJECT}_default" --entrypoint clickhouse-client "$CH_IMAGE" \
  --host clickhouse --port 9000 -q "SELECT 1" 2>&1 | grep -oE 'Connection refused|Authentication failed' | head -1 || true)
[ "$o" = "Connection refused" ] && ok=1 || ok=0; row transit "plain native 9000 from another container" "Connection refused" "${o:-answered}" $ok
row transit "migration connection (CLICKHOUSE_MIGRATION_SSL=true)" "read from the image" \
  "up.sh appends secure=true&skip_verify=true: TLS without certificate check" info

echo "════ 3. At rest: ClickHouse encrypted disk ════"
o=$(chq -q "SELECT is_encrypted FROM system.disks WHERE name = 'encrypted_disk'"); [ "$o" = 1 ] && ok=1 || ok=0
row clickhouse "system.disks: encrypted_disk is_encrypted" 1 "${o:-none}" $ok
o=$(chq -q "SELECT groupUniqArray(storage_policy) FROM system.tables WHERE database = 'default' AND engine LIKE '%MergeTree'")
[ "$o" = "['encrypted_policy']" ] && ok=1 || ok=0; row clickhouse "storage policy of every Langfuse MergeTree table" "['encrypted_policy']" "$o" $ok
o=$(chq -q "SELECT name || '=' || storage_policy FROM system.tables WHERE database = 'system' AND name IN ('query_log', 'part_log', 'text_log') ORDER BY name FORMAT CSV" | tr -d '"' | paste -sd' ' -)
row clickhouse "system log tables" "reported" "${o:-none}" info

ENC="lab17-enc-$(openssl rand -hex 12)"
TID=$(send_trace "$ENC")
v=$(api_input "$TID"); [ "$v" = "$ENC" ] && ok=1 || ok=0
row clickhouse "trace input through the public API (decrypted on read)" "the sentinel" "${v:-nothing}" $ok
o=$(chq -q "SELECT groupUniqArray(disk_name) FROM system.parts WHERE database = 'default' AND table = 'events_full' AND active")
[ "$o" = "['encrypted_disk']" ] && ok=1 || ok=0; row clickhouse "events_full parts" "['encrypted_disk']" "$o" $ok
chq -q "SYSTEM FLUSH LOGS" >/dev/null
h=$(rawgrep langfuse_clickhouse_encrypted_data "$ENC"); n=$(count "$h")
[ "$n" = 0 ] && ok=1 || ok=0; row clickhouse "raw files with the trace sentinel (whole data volume)" 0 "$n${h:+: $(echo "$h" | head -3 | paste -sd' ' -)}" $ok
h=$(rawgrep langfuse_clickhouse_logs "$ENC"); n=$(count "$h")
row clickhouse "server log files with the trace sentinel" "reported" "$n" info

CTL="lab17-ctl-$(openssl rand -hex 12)"
chq -q "DROP TABLE IF EXISTS default.lab17_ctl_plain SYNC"; chq -q "DROP TABLE IF EXISTS default.lab17_ctl_enc SYNC"
chq -q "CREATE TABLE default.lab17_ctl_plain (s String CODEC(NONE)) ENGINE = MergeTree ORDER BY tuple() SETTINGS storage_policy = 'default'"
chq -q "CREATE TABLE default.lab17_ctl_enc (s String CODEC(NONE)) ENGINE = MergeTree ORDER BY tuple()"
for t in plain enc; do printf '%s\n' "$CTL" | chq -q "INSERT INTO default.lab17_ctl_$t FORMAT TSV"; done
PLAIN_DIR=$(chq -q "SELECT data_paths[1] FROM system.tables WHERE name = 'lab17_ctl_plain'" | sed 's#^/var/lib/clickhouse/##')
ENC_DIR=$(chq -q "SELECT data_paths[1] FROM system.tables WHERE name = 'lab17_ctl_enc'" | sed 's#^/var/lib/clickhouse/##')
n=$(count "$(rawgrep langfuse_clickhouse_encrypted_data "$CTL" "$PLAIN_DIR")")
[ "$n" -ge 1 ] && ok=1 || ok=0; row clickhouse "control: CODEC(NONE) table on the plain disk" ">=1 file" "$n ($PLAIN_DIR)" $ok
n=$(count "$(rawgrep langfuse_clickhouse_encrypted_data "$CTL" "$ENC_DIR")")
[ "$n" = 0 ] && ok=1 || ok=0; row clickhouse "same table on the encrypted disk" 0 "$n ($ENC_DIR)" $ok
chq -q "DROP TABLE default.lab17_ctl_plain SYNC"; chq -q "DROP TABLE default.lab17_ctl_enc SYNC"

echo "════ 4. At rest: MinIO SSE-S3 ════"
MC=(lf_compose ee encryption -- exec -T -e "MC_HOST_lab=http://${MINIO_ROOT_USER:-minio}:${MINIO_ROOT_PASSWORD:-miniosecret}@localhost:9000" minio mc)
KEY=""
for k in $("${MC[@]}" find "lab/langfuse/events/otel/$PROJ" --newer-than 10m 2>/dev/null | sed 's#^lab/langfuse/##'); do
  "${MC[@]}" cat "lab/langfuse/$k" 2>/dev/null | grep -qF "$ENC" && { KEY="$k"; break; }
done
[ -n "$KEY" ] && ok=1 || ok=0; row minio "event object for the trace, read through S3 (decrypted)" "found" "${KEY:-none}" $ok
sse=$("${MC[@]}" stat --json "lab/langfuse/$KEY" 2>/dev/null | jq -r '.metadata["X-Amz-Server-Side-Encryption"] // "none"')
[ "$sse" = AES256 ] && ok=1 || ok=0; row minio "X-Amz-Server-Side-Encryption of that object" AES256 "$sse" $ok
n=$(count "$(rawgrep langfuse_minio_data "$ENC")"); [ "$n" = 0 ] && ok=1 || ok=0
row minio "raw files with the trace sentinel (whole data volume)" 0 "$n" $ok
CTL_S3="lab17-s3ctl-$(openssl rand -hex 12)"
printf '%s\n' "$CTL_S3" | "${MC[@]}" pipe "lab/langfuse/lab17-control/plain-$TS.txt" >/dev/null
n=$(count "$(rawgrep langfuse_minio_data "$CTL_S3")"); [ "$n" -ge 1 ] && ok=1 || ok=0
row minio "control: object written without SSE" ">=1 file" "$n" $ok
"${MC[@]}" rm --recursive --force lab/langfuse/lab17-control/ >/dev/null 2>&1 || true

echo "════ 5. Application level: what Postgres holds ════"
LLM_SECRET="sk-lab17-$(openssl rand -hex 16)"; LLM_NAME="lab17-$TS"
# No baseURL: the public API refuses loopback and private addresses ("Blocked IP address detected").
r=$(jq -n --arg p "$LLM_NAME" --arg s "$LLM_SECRET" \
  '{provider:$p,adapter:"openai",secretKey:$s,customModels:["lab17-model"],withDefaultModels:false}' |
  curl -sS -m 30 -w '\n%{http_code}' -u "$AUTH" -X PUT "$HOST/api/public/llm-connections" -H "Content-Type: application/json" -d @-)
code=$(echo "$r" | tail -1); disp=$(echo "$r" | sed '$d' | jq -r '.displaySecretKey // empty'); LLM_ID=$(echo "$r" | sed '$d' | jq -r '.id // empty')
case "$code" in 200|201) ok=1 ;; *) ok=0 ;; esac; row postgres "LLM connection created (public API)" "HTTP 200 or 201" "HTTP $code, displaySecretKey=$disp" $ok
lf_compose -- exec -T postgres pg_dump -U "${POSTGRES_USER:-postgres}" --data-only "${POSTGRES_DB:-postgres}" > "$WORK/pg.sql"
n=$(grep -cF -- "$LLM_SECRET" "$WORK/pg.sql" || true); [ "$n" = 0 ] && ok=1 || ok=0
row postgres "LLM secret in a full data dump" 0 "$n" $ok
n=$(grep -cF -- "$LLM_NAME" "$WORK/pg.sql" || true); [ "$n" -ge 1 ] && ok=1 || ok=0
row postgres "control: the connection name in the same dump" ">=1" "$n" $ok
n=$(grep -cF -- "$LANGFUSE_SECRET_KEY" "$WORK/pg.sql" || true); [ "$n" = 0 ] && ok=1 || ok=0
row postgres "project API secret key in the dump" 0 "$n" $ok
n=$(grep -cF -- "$LANGFUSE_PUBLIC_KEY" "$WORK/pg.sql" || true); [ "$n" -ge 1 ] && ok=1 || ok=0
row postgres "control: project API public key in the dump" ">=1" "$n" $ok
[ -n "$LLM_ID" ] && curl -sS -m 30 -o /dev/null -u "$AUTH" -X DELETE "$HOST/api/public/llm-connections/$LLM_ID" || true

echo "════ Restore: plain overlay set, original ClickHouse volume ════"
lf_compose ee -- up -d >/dev/null 2>&1
wait_health
o=$(lf_compose -- exec -T clickhouse clickhouse-client --user "$CH_USER" --password "$CH_PASS" \
  -q "SELECT count() > 0 FROM default.events_core" 2>&1 | tail -1)
[ "$o" = 1 ] && ok=1 || ok=0; row restore "plain ClickHouse on the original volume has the earlier labs' data" 1 "$o" $ok

echo
echo "════ Summary ════"
column -t -s $'\t' "$ROWS"
echo
if [ "$FAILS" = 0 ]; then echo "✅ all checks passed ($(grep -c PASS "$ROWS") PASS, $(grep -c INFO "$ROWS") INFO)"; else echo "✗ $FAILS check(s) failed"; exit 1; fi
