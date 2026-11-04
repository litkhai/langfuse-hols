#!/usr/bin/env bash
# 06 — chart v2 + Langfuse v3: is everything there, and do the old credentials still work?
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1: $2"; else echo "FAIL  $1: expected $3, got $2"; fail=1; fi; }

log "versions on the v2 release"
kx -n "$NS" get pods -l app.kubernetes.io/instance="$V2" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
kx -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' | grep "$V2-clickhouse\|$V2-keeper" || true
echo "ClickHouse $(v2_ch -q 'SELECT version()') · Postgres $(v2_psql -c 'SHOW server_version')"
echo "v1 deployments: $(kx -n "$NS" get deploy "$V1-web" "$V1-worker" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas} {end}')"

log "store contents: v1 before the copy vs v2 now (traffic traces are compared separately)"
./inventory.sh v2 >"$WORK/inventory-v2-after.txt"
# Everything that existed before 05 started must be on v2 with the same count; ClickHouse and S3
# also received the traffic written during 05, so they are compared as >=.
while read -r k v; do
  n=$(awk -v k="$k" '$1==k {print $2}' "$WORK/inventory-v2-after.txt")
  case $k in
    pg.audit_logs|pg.background_migrations|ch.events_*) continue ;;
    ch.*|s3.*) [ "$n" != - ] && [ "$v" != - ] && [ "$n" -ge "$v" ] && echo "PASS  $k: v1 $v, v2 $n" || { echo "FAIL  $k: v1 $v, v2 $n"; fail=1; } ;;
    *) check "$k" "$n" "$v" ;;
  esac
done <"$WORK/inventory-v1-before.txt"

log "traffic written during the migration: accepted by v1 or v2, and present on v2"
accepted=$(awk '$2 ~ /^20/ {print $3}' "$WORK/traffic.log" | sort -u)
n_acc=$(printf '%s\n' "$accepted" | grep -c . || true)
ids=$(printf "'%s'," $accepted); ids=${ids%,}
n_v2=$(v2_ch -q "SELECT count() FROM traces FINAL WHERE id IN ($ids)")
echo "accepted $n_acc, on v2 $n_v2"
check "accepted traffic traces on v2" "$n_v2" "$n_acc"
./traffic.sh report

log "the old API keys and the old password still work (salt, encryption key, NextAuth secret reused)"
url=$(pf app langfuse-app 3000); trap 'pf_stop app' EXIT
curl -s "$url/api/public/health"; echo
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$LF_PK:$LF_SK" "$url/api/public/projects")
check "GET /api/public/projects with the v1 keys" "$code" 200
t=$(head -1 "$WORK/sent.jsonl" | jq -r .trace_id)
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$LF_PK:$LF_SK" "$url/api/public/traces/$t")
check "GET /api/public/traces/<first seeded trace>" "$code" 200
csrf=$(curl -s -c "$WORK/jar" "$url/api/auth/csrf" | jq -r .csrfToken)
curl -s -b "$WORK/jar" -c "$WORK/jar" -o /dev/null -X POST "$url/api/auth/callback/credentials" \
  --data-urlencode "csrfToken=$csrf" --data-urlencode "email=$LF_USER" --data-urlencode "password=$LF_PASSWORD"
email=$(curl -s -b "$WORK/jar" "$url/api/auth/session" | jq -r '.user.email // empty')
check "password sign-in as the v1 admin" "$email" "$LF_USER"
exit $fail
