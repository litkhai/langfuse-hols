#!/usr/bin/env bash
# 06 — the v4 release next to v3: Postgres option (b) (a new database on the same server, restored
# from a dump of v3's), ClickHouse database langfuse_v4 on the same cluster, Redis key prefix.
# The historic backfill stays off until 07 has copied the ClickHouse data.
# Then the secrets check: v3's API key, session cookie, encrypted LLM key and media on v4.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh

log "gate: every v3 background migration finished (v4 drops tables they emptied)"
check "unfinished or failed background migrations on v3" \
  "$(psql_ langfuse -c "SELECT count(*) FROM background_migrations WHERE finished_at IS NULL OR failed_at IS NOT NULL")" 0

log "Postgres (b): dump v3's database, restore into a new database on the same server"
t0=$(now)
psql_ postgres -c "DROP DATABASE IF EXISTS langfuse_v4 WITH (FORCE)" >/dev/null
psql_ postgres -c "CREATE DATABASE langfuse_v4"
kx -n "$NS" exec pg-main-0 -- sh -c "PGPASSWORD=$PG_PW pg_dump -U postgres -Fc langfuse >/tmp/v3.dump && \
  PGPASSWORD=$PG_PW pg_restore -U postgres -d langfuse_v4 --no-owner /tmp/v3.dump && ls -l /tmp/v3.dump | awk '{print \"dump\", \$5, \"bytes\"}'"
echo "dump + restore: $(elapsed "$t0") s"

log "ClickHouse: database langfuse_v4 on the same cluster (v4 migrations do not create the database)"
ch -q "CREATE DATABASE IF NOT EXISTS langfuse_v4 ON CLUSTER default" --format Null
ch -q "SELECT name, engine FROM system.databases WHERE name IN ('default', 'langfuse_v4') FORMAT TSV"

log "lf-v4-env: Postgres URL, Redis key prefix, backfill gate off"
kx -n "$NS" delete configmap lf-v4-env --ignore-not-found >/dev/null
v4env "DATABASE_URL=postgresql://postgres:$PG_PW@pg-main:5432/langfuse_v4" "REDIS_KEY_PREFIX=lf-v4" \
  "LANGFUSE_BACKGROUND_MIGRATION_V4_ENABLE_HISTORIC_BACKFILL=false"
sed "s/:$PG_PW@/:***@/" "$WORK/v4env.env"   # no password in the log

log "helm install $V4 chart $CHART_V2, Langfuse $LF_V4 (events_only, the v4 default)"
t0=$(now); v4_install; echo "install (Prisma + ClickHouse migrations, pods ready): $(elapsed "$t0") s"
kx -n "$NS" rollout restart deploy/"$V4"-langfuse-worker >/dev/null
kx -n "$NS" rollout status deploy/"$V4"-langfuse-worker --timeout=600s >/dev/null
kx -n "$NS" get pods -l app.kubernetes.io/instance=$V4

# Race on a first install: helm starts web and worker together; web applies the Prisma migrations,
# then the ClickHouse ones, while the worker already runs background migrations. On the first run
# 20261110_backfill_audit_logs_to_clickhouse failed with "ClickHouse audit_logs table does not exist"
# 22 s before web's ClickHouse migration created that table. A failed row is never retried, so
# clear it and restart the worker.
log "background migrations that failed during the install race"
psql_ langfuse_v4 -c "SELECT name, left(failed_reason, 100) FROM background_migrations WHERE failed_at IS NOT NULL"
psql_ langfuse_v4 -c "UPDATE background_migrations SET failed_at = NULL, failed_reason = NULL, locked_at = NULL, worker_id = NULL WHERE failed_at IS NOT NULL"
kx -n "$NS" rollout restart deploy/"$V4"-langfuse-worker >/dev/null
kx -n "$NS" rollout status deploy/"$V4"-langfuse-worker --timeout=600s >/dev/null
sleep 30
# 20261110_backfill_audit_logs_to_clickhouse copies the Postgres audit log and then waits ~10 min for
# rows "to settle" before it finishes, so only failures are checked here (07 waits for the chain).
check "failed background migrations on v4 after the reset" \
  "$(psql_ langfuse_v4 -c "SELECT count(*) FROM background_migrations WHERE failed_at IS NOT NULL")" 0

log "what v4 built"
echo "ClickHouse schema version (langfuse_v4): $(ch -q 'SELECT version FROM langfuse_v4.schema_migrations ORDER BY sequence DESC LIMIT 1') (v3 default: $(ch -q 'SELECT version FROM default.schema_migrations ORDER BY sequence DESC LIMIT 1'))"
ch -q "SELECT name, engine FROM system.tables WHERE database = 'langfuse_v4' ORDER BY name FORMAT TSV"
echo "Prisma migrations: v3 db $(psql_ langfuse -c 'SELECT count(*) FROM _prisma_migrations') / v4 db $(psql_ langfuse_v4 -c 'SELECT count(*) FROM _prisma_migrations')"
psql_ langfuse_v4 -c "SELECT 'v4 Prisma migrations ran in ' || round(extract(epoch FROM max(finished_at) - min(started_at))::numeric, 1) || ' s' FROM _prisma_migrations WHERE migration_name > '20260423084654_add_datasets_remote_experiment_enabled_col'"
psql_ langfuse_v4 -c "SELECT string_agg(tablename, ' ' ORDER BY tablename) FROM pg_tables WHERE schemaname='public' AND tablename IN ('traces','observations','scores','dataset_run_items')" | sed 's/^/legacy PG tables left in langfuse_v4: /'
psql_ langfuse_v4 -c "SELECT name, finished_at IS NOT NULL AS finished, args->>'envGate' AS gate FROM background_migrations ORDER BY name"
echo "role_assignments rows (new in v4, backfilled from api_keys and memberships): $(psql_ langfuse_v4 -c 'SELECT count(*) FROM role_assignments')"

url=$(pf v4 "$V4"-langfuse-web 3000); v3url=$(pf v3 "$V3"-langfuse-web 3000); trap 'pf_stop v4; pf_stop v3' EXIT
curl -s "$url/api/public/health"; echo

log "Q6 secrets: the v3 project API key on v4"
check "GET /api/public/projects with the v3 key on v4" "$(api "$url" GET /api/public/projects)" 200
check "same call, wrong secret key (negative control)" \
  "$(curl -s -o /dev/null -w '%{http_code}' -u "$LF_PK:sk-lf-wrong" "$url/api/public/projects")" 401

log "Q6 secrets: a session cookie issued by v3, presented to v4 (NEXTAUTH_SECRET)"
"$PY" ui.py login "$v3url" "$WORK/v3.jar"
check "v4 /api/auth/session with the v3 cookie" "$("$PY" ui.py session "$url" "$WORK/v3.jar" | jq -r .user)" "$LF_USER"
sed 's/\(session-token="\)[^"]*/\1tampered/' "$WORK/v3.jar" >"$WORK/bad.jar"
check "same with a tampered cookie (negative control)" "$("$PY" ui.py session "$url" "$WORK/bad.jar" | jq -r .user)" null

log "Q6 secrets: the LLM key v3 encrypted, decrypted by v4 (testUpdate sends it to mock-llm)"
"$PY" ui.py login "$url" "$WORK/v4.jar"
llm_id=$(psql_ langfuse_v4 -c "SELECT id FROM llm_api_keys LIMIT 1")
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
"$PY" ui.py trpc "$url" "$WORK/v4.jar" llmApiKey.testUpdate \
  "{\"projectId\":\"$LF_PROJECT\",\"id\":\"$llm_id\",\"provider\":\"mock-openai\",\"adapter\":\"openai\",\"baseURL\":\"http://mock-llm:8080/v1\",\"customModels\":[\"mock-model\"],\"withDefaultModels\":false}" | tee "$WORK/llm-test.json" | head -c 400; echo
sleep 2
seen=$(kx -n "$NS" logs deploy/mock-llm --since-time="$since" | awk '/^AUTH/ {print $3; exit}')
check "API key mock-llm received from v4" "$seen" "sk-mock-sbs-lab-0001"

log "Q5 media: the v3 attachment through v4 (row copied with the PG dump, object in v3's prefix)"
mid=$(jq -r 'select(.producer=="media") | .media_id' "$WORK/sent.jsonl" | head -1)
sha=$(jq -r 'select(.producer=="media") | .sha256' "$WORK/sent.jsonl" | head -1)
psql_ langfuse_v4 -c "SELECT bucket_name, bucket_path FROM media WHERE id = '$mid'"
murl=$(apij "$url" "/api/public/media/$mid" | jq -r .url)
echo "presigned by v4: ${murl%%\?*}"
got=$(kx -n "$NS" exec lab-curl -- sh -c "curl -s '$murl' | sha256sum" | awk '{print $1}' | xxd -r -p | base64)
check "sha256 of the object v4 links to" "$got" "$sha"
exit $fail
