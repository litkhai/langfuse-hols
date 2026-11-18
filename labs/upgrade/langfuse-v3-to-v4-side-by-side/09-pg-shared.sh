#!/usr/bin/env bash
# 09 — Postgres option (c), Redis sharing, and wrong secrets, on a scratch pair so the main
# releases are untouched:
#   lf-v3c  Langfuse 3.172.1 on Postgres database langfuse_c (a copy of v3's), ClickHouse db v3c
#   lf-v4c  Langfuse 4.82.0 on the SAME Postgres database langfuse_c, ClickHouse db v4c
#   both    Redis db index 1 with no key prefix first (the collision), then v4c with a prefix
# The main v4 is scaled to 0 while this runs (memory); the main v3 keeps running on Redis db 0.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
C3=lf-v3c; C4=lf-v4c
in_db() {  # in_db <ch-db> <ids...>: how many of the trace ids are in that database (traces or events_full)
  local db=$1; shift; local list; list=$(printf "'%s'," "$@"); list=${list%,}
  ch -q "SELECT uniqExact(id) FROM (SELECT id FROM $db.traces WHERE id IN ($list)
         $( [ "$db" = v4c ] && echo "UNION ALL SELECT trace_id AS id FROM $db.events_full WHERE trace_id IN ($list)" ))"
}
sent_ids() { jq -r "select(.phase==\"$1\") | .trace_id" "$WORK/sent.jsonl"; }

kx -n "$NS" scale deploy/"$V4"-langfuse-web deploy/"$V4"-langfuse-worker --replicas=0 >/dev/null

log "scratch stores: langfuse_c (dump of v3's database), ClickHouse v3c and v4c, Redis db 1 empty"
psql_ postgres -c "DROP DATABASE IF EXISTS langfuse_c WITH (FORCE)" >/dev/null
psql_ postgres -c "CREATE DATABASE langfuse_c" >/dev/null
kx -n "$NS" exec pg-main-0 -- sh -c "PGPASSWORD=$PG_PW pg_dump -U postgres -Fc langfuse | PGPASSWORD=$PG_PW pg_restore -U postgres -d langfuse_c --no-owner"
for d in v3c v4c; do ch -q "DROP DATABASE IF EXISTS $d ON CLUSTER default SYNC" --format Null; ch -q "CREATE DATABASE $d ON CLUSTER default" --format Null; done
rcli -n 1 FLUSHDB >/dev/null
sed -e 's#pg-main:5432/langfuse"#pg-main:5432/langfuse_c"#' -e 's#6379/0#6379/1#' -e 's#database: default#database: v3c#' \
    -e 's#"events/"#"c/v3/events/"#' -e 's#"exports/"#"c/v3/exports/"#' -e 's#"media/"#"c/v3/media/"#' values/v3.yaml >"$WORK/v3c.yaml"
sed -e 's#lf-v4-env#lf-v4c-env#g' -e 's#6379/0#6379/1#' -e 's#database: langfuse_v4#database: v4c#' -e 's#"v4/#"c/v4/#g' values/v4.yaml >"$WORK/v4c.yaml"
grep -q langfuse_c "$WORK/v3c.yaml" && grep -q 6379/1 "$WORK/v3c.yaml" && grep -q 'database: v4c' "$WORK/v4c.yaml" || die "scratch values not rewritten"
kx -n "$NS" create configmap lf-v4c-env --from-literal=DATABASE_URL="postgresql://postgres:$PG_PW@pg-main:5432/langfuse_c" \
  --from-literal=LANGFUSE_BACKGROUND_MIGRATION_V4_ENABLE_HISTORIC_BACKFILL=false --dry-run=client -o yaml | kx -n "$NS" apply -f - >/dev/null

log "lf-v3c: Langfuse $LF_V3 on langfuse_c"
hx upgrade --install "$C3" "$CHART" --version "$CHART_V1" -n "$NS" -f "$WORK/v3c.yaml" --set langfuse.image.tag="$LF_V3" --wait --timeout 15m >/dev/null
kx -n "$NS" rollout restart deploy/"$C3"-langfuse-worker >/dev/null; kx -n "$NS" rollout status deploy/"$C3"-langfuse-worker --timeout=600s >/dev/null
u3=$(pf c3 "$C3"-langfuse-web 3000); trap 'pf_stop c3; pf_stop c4' EXIT
export LANGFUSE_PUBLIC_KEY=$LF_PK LANGFUSE_SECRET_KEY=$LF_SK
LANGFUSE_HOST=$u3 "$PY" produce.py traces --phase c-v3-alone --n 5 >/dev/null
sleep 20
check "v3c alone: its traces in v3c" "$(in_db v3c $(sent_ids c-v3-alone))" 5

log "lf-v4c: Langfuse $LF_V4 on the SAME database, while v3c serves (probe v3c every second)"
kx -n "$NS" exec lab-curl -- sh -c "rm -f /tmp/stop-c; (while [ ! -f /tmp/stop-c ]; do
  h=\$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://$C3-langfuse-web:3000/api/public/health)
  p=\$(curl -s -m 2 -o /dev/null -w '%{http_code}' -u $LF_PK:$LF_SK http://$C3-langfuse-web:3000/api/public/v2/prompts/support-system)
  echo \"\$(date +%s) \$h \$p\"; sleep 1; done) >/tmp/c-probe.log 2>&1 &"
t0=$(now)
hx upgrade --install "$C4" "$CHART" --version "$CHART_V2" -n "$NS" -f "$WORK/v4c.yaml" --set langfuse.image.tag="$LF_V4" --wait --timeout 20m >/dev/null
echo "v4c install (94 Prisma migrations on v3c's live database): $(elapsed "$t0") s"
kx -n "$NS" rollout restart deploy/"$C4"-langfuse-worker >/dev/null; kx -n "$NS" rollout status deploy/"$C4"-langfuse-worker --timeout=600s >/dev/null
sleep 10; kx -n "$NS" exec lab-curl -- touch /tmp/stop-c; sleep 2
kx -n "$NS" exec lab-curl -- cat /tmp/c-probe.log >"$WORK/c-probe.log"
awk '{h[$2]++; p[$3]++} END {for (k in h) printf "v3c health %s: %d\n", k, h[k]; for (k in p) printf "v3c prompt API %s: %d\n", k, p[k]}' "$WORK/c-probe.log"
echo "Prisma migrations in langfuse_c: $(psql_ langfuse_c -c 'SELECT count(*) FROM _prisma_migrations')"
u4=$(pf c4 "$C4"-langfuse-web 3000)

log "(c) v3c on the migrated database: reads and writes through its API"
check "v3c GET /api/public/projects" "$(api "$u3" GET /api/public/projects)" 200
check "v3c GET /api/public/v2/prompts/support-system" "$(api "$u3" GET /api/public/v2/prompts/support-system)" 200
check "v3c GET /api/public/v2/datasets/support-golden" "$(api "$u3" GET /api/public/v2/datasets/support-golden)" 200
check "v3c GET /api/public/llm-connections" "$(api "$u3" GET /api/public/llm-connections)" 200
check "v3c POST /api/public/v2/prompts (new version)" "$(api "$u3" POST /api/public/v2/prompts '{"name":"support-system","type":"text","prompt":"v3c write after v4 migrated","labels":[]}')" 201
check "v3c POST /api/public/dataset-items" "$(api "$u3" POST /api/public/dataset-items '{"datasetName":"support-golden","input":{"question":"written by v3c"}}')" 200
check "v4c sees the prompt version v3c wrote" "$(apij "$u4" '/api/public/v2/prompts/support-system?version=2' | jq -r .prompt)" "v3c write after v4 migrated"

log "(c) v3c UI (tRPC) on the migrated database"
"$PY" ui.py login "$u3" "$WORK/c3.jar" >/dev/null
for q in "prompts.all|{\"projectId\":\"$LF_PROJECT\",\"page\":0,\"limit\":10,\"filter\":[],\"orderBy\":{\"column\":\"createdAt\",\"order\":\"DESC\"}}" \
         "datasets.allDatasetMeta|{\"projectId\":\"$LF_PROJECT\"}" \
         "evals.allConfigs|{\"projectId\":\"$LF_PROJECT\",\"filter\":[],\"page\":0,\"limit\":10}" \
         "projectApiKeys.byProjectId|{\"projectId\":\"$LF_PROJECT\"}" \
         "llmApiKey.all|{\"projectId\":\"$LF_PROJECT\"}" \
         "members.allFromProject|{\"projectId\":\"$LF_PROJECT\",\"orgId\":\"sbs-lab-org\",\"page\":0,\"limit\":10}" \
         "backgroundMigrations.all|{}"; do
  proc=${q%%|*}; in=${q#*|}
  echo "v3c tRPC $proc: $("$PY" ui.py trpc "$u3" "$WORK/c3.jar" "$proc" "$in" --query | jq -c '{http, error: (.body[0].error.json.message // null | tostring | .[0:120])}')"
done

log "(c) an API key created on v3c after the v4 migration"
key=$("$PY" ui.py trpc "$u3" "$WORK/c3.jar" projectApiKeys.create "{\"projectId\":\"$LF_PROJECT\",\"note\":\"created on v3c\"}" | jq -r '.body[0].result.data.json | "\(.publicKey):\(.secretKey)"')
echo "new key: ${key:0:9}… (public key, shortened in the log)"
check "new v3c key on v3c" "$(curl -s -o /dev/null -w '%{http_code}' -u "$key" "$u3/api/public/projects")" 200
check "new v3c key on v4c (no role_assignments row)" "$(curl -s -o /dev/null -w '%{http_code}' -u "$key" "$u4/api/public/projects")" 200
check "new v3c key: OTel ingestion on v4c" "$(curl -s -o /dev/null -w '%{http_code}' -u "$key" -H 'Content-Type: application/json' -X POST "$u4/api/public/otel/v1/traces" -d '{"resourceSpans":[]}')" 200
echo "role_assignments for it: $(psql_ langfuse_c -c "SELECT count(*) FROM role_assignments r JOIN api_keys k ON r.principal_api_key_id = k.id OR r.api_key_id = k.id WHERE k.public_key = '${key%%:*}'")"

log "(c) restarts: v3c web (prisma migrate deploy sees 94 unknown migrations) and v3c worker (v4 rows in background_migrations)"
kx -n "$NS" rollout restart deploy/"$C3"-langfuse-web >/dev/null
if kx -n "$NS" rollout status deploy/"$C3"-langfuse-web --timeout=300s >/dev/null; then echo "v3c web restarted: ready"; else echo "v3c web restarted: NOT ready"; fi
kx -n "$NS" logs deploy/"$C3"-langfuse-web --tail=400 | grep -iE 'migration|warn|error' | grep -v '^\s*$' | head -8
kx -n "$NS" rollout restart deploy/"$C3"-langfuse-worker >/dev/null; kx -n "$NS" rollout status deploy/"$C3"-langfuse-worker --timeout=300s >/dev/null
sleep 20
kx -n "$NS" logs deploy/"$C3"-langfuse-worker --tail=2000 | grep -i 'background migration' | grep -ioE '(found background migrations [^ ]+ to run|error[^{]{0,160}|no background migrations to run)' | sort | uniq -c | head -8
pf_stop c3; u3=$(pf c3 "$C3"-langfuse-web 3000)

log "Redis shared, no prefix (both on db 1): who processes whose ingestion jobs?"
LANGFUSE_HOST=$u3 "$PY" produce.py traces --phase c-shared-redis-to-v3 --n 20 >/dev/null
LANGFUSE_HOST=$u3 "$PY" produce.py legacy-http --phase c-shared-redis-to-v3 --n 10 >/dev/null
LANGFUSE_HOST=$u4 "$PY4" produce.py traces --phase c-shared-redis-to-v4 --n 20 >/dev/null
sleep 45
ids3=$(sent_ids c-shared-redis-to-v3); ids4=$(sent_ids c-shared-redis-to-v4)
echo "sent to v3c (30): in v3c $(in_db v3c $ids3), in v4c $(in_db v4c $ids3)"
echo "sent to v4c (20): in v4c $(in_db v4c $ids4), in v3c $(in_db v3c $ids4)"
rcli -n 1 --scan --count 1000 | grep -oE '^[^:]+:[^:]+' | sort | uniq -c | sort -rn | head -12
kx -n "$NS" logs deploy/"$C3"-langfuse-worker --since=2m | grep -ioE '(unknown job|no handler|invalid[^"]{0,60}|zod[^"]{0,60}|error[^"{]{0,100})' | sort | uniq -c | sort -rn | head -5

log "Redis: v4c with REDIS_KEY_PREFIX=lf-v4c (same instance, same db index)"
kx -n "$NS" patch configmap lf-v4c-env --type merge -p '{"data":{"REDIS_KEY_PREFIX":"lf-v4c"}}' >/dev/null
restart "$C4"; pf_stop c4; u4=$(pf c4 "$C4"-langfuse-web 3000)
LANGFUSE_HOST=$u3 "$PY" produce.py traces --phase c-prefixed-to-v3 --n 20 >/dev/null
LANGFUSE_HOST=$u3 "$PY" produce.py legacy-http --phase c-prefixed-to-v3 --n 10 >/dev/null
LANGFUSE_HOST=$u4 "$PY4" produce.py traces --phase c-prefixed-to-v4 --n 20 >/dev/null
sleep 45
ids3=$(sent_ids c-prefixed-to-v3); ids4=$(sent_ids c-prefixed-to-v4)
check "prefixed: sent to v3c, in v3c" "$(in_db v3c $ids3)" 30
check "prefixed: sent to v3c, in v4c" "$(in_db v4c $ids3)" 0
check "prefixed: sent to v4c, in v4c" "$(in_db v4c $ids4)" 20
check "prefixed: sent to v4c, in v3c" "$(in_db v3c $ids4)" 0
rcli -n 1 --scan --count 1000 | grep -oE '^[^:]+:[^:]+' | sort | uniq -c | sort -rn | head -12

log "wrong secrets on v4c (a different SALT, ENCRYPTION_KEY and NEXTAUTH_SECRET)"
kx -n "$NS" create secret generic langfuse-wrong --from-literal=salt="$(openssl rand -base64 32)" \
  --from-literal=encryption-key="$(openssl rand -hex 32)" --from-literal=nextauth-secret="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml | kx -n "$NS" apply -f - >/dev/null
hx upgrade "$C4" "$CHART" --version "$CHART_V2" -n "$NS" -f "$WORK/v4c.yaml" --set langfuse.image.tag="$LF_V4" \
  --set langfuse.salt.secretKeyRef.name=langfuse-wrong --set langfuse.encryptionKey.secretKeyRef.name=langfuse-wrong \
  --set langfuse.nextauth.secret.secretKeyRef.name=langfuse-wrong --wait --timeout 15m >/dev/null
pf_stop c4; u4=$(pf c4 "$C4"-langfuse-web 3000)
hash_before=$(psql_ langfuse_c -c "SELECT fast_hashed_secret_key FROM api_keys WHERE public_key = '$LF_PK'")
echo "project API key on v4c, wrong SALT: $(api "$u4" GET /api/public/projects)"
hash_after=$(psql_ langfuse_c -c "SELECT fast_hashed_secret_key FROM api_keys WHERE public_key = '$LF_PK'")
[ "$hash_before" = "$hash_after" ] && echo "fast_hashed_secret_key unchanged" || echo "fast_hashed_secret_key rewritten by v4c (salt differs)"
echo "same key on v3c afterwards: $(api "$u3" GET /api/public/projects)"
hash_v3=$(psql_ langfuse_c -c "SELECT fast_hashed_secret_key FROM api_keys WHERE public_key = '$LF_PK'")
[ "$hash_after" = "$hash_v3" ] && echo "fast_hashed_secret_key unchanged by v3c" || echo "fast_hashed_secret_key rewritten back by v3c"
"$PY" ui.py login "$u3" "$WORK/c3.jar" >/dev/null
echo "v3c session cookie on v4c, wrong NEXTAUTH_SECRET: user=$("$PY" ui.py session "$u4" "$WORK/c3.jar" | jq -r .user)"
"$PY" ui.py login "$u4" "$WORK/c4.jar" >/dev/null
llm_id=$(psql_ langfuse_c -c "SELECT id FROM llm_api_keys LIMIT 1")
payload="{\"projectId\":\"$LF_PROJECT\",\"id\":\"$llm_id\",\"provider\":\"mock-openai\",\"adapter\":\"openai\",\"baseURL\":\"http://mock-llm:8080/v1\",\"customModels\":[\"mock-model\"],\"withDefaultModels\":false}"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
res=$("$PY" ui.py trpc "$u4" "$WORK/c4.jar" llmApiKey.testUpdate "$payload" | jq -c '{http, result: .body[0].result.data.json, error: (.body[0].error.json.message // null | tostring | .[0:160])}')
echo "LLM key test on v4c, wrong ENCRYPTION_KEY: $res"
sleep 2
echo "key mock-llm received: $(kx -n "$NS" logs deploy/mock-llm --since-time="$since" | awk '/^AUTH/ {print $3; exit}')"

log "teardown of the scratch pair; main v4 back"
pf_stop c3; pf_stop c4
hx uninstall "$C3" "$C4" -n "$NS" --wait >/dev/null
kx -n "$NS" delete configmap lf-v4c-env --ignore-not-found >/dev/null
kx -n "$NS" delete secret langfuse-wrong --ignore-not-found >/dev/null
for d in v3c v4c; do ch -q "DROP DATABASE IF EXISTS $d ON CLUSTER default SYNC" --format Null; done
psql_ postgres -c "DROP DATABASE IF EXISTS langfuse_c WITH (FORCE)" >/dev/null
rcli -n 1 FLUSHDB >/dev/null
kx -n "$NS" scale deploy/"$V4"-langfuse-web deploy/"$V4"-langfuse-worker --replicas=1 >/dev/null
kx -n "$NS" rollout status deploy/"$V4"-langfuse-web --timeout=600s >/dev/null
exit $fail
