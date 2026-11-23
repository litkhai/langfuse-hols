#!/usr/bin/env bash
# 05-bench.sh [million observations, default 6] — raw table vs the views' tables, at a size where it shows.
#
# The traces of 02 are a few thousand rows; at that size every query takes milliseconds either way. So this
# step builds lab_langfuse_ch_mv_bench: events_full_mv, a copy of events_full's DDL (CREATE TABLE … AS
# default.events_full: same engine, sorting key, skip and text indexes), with the three views of 03 attached
# to it (same SELECT, read from system.tables), then fills it with synthetic observations: 3 per trace
# (root span, retrieval span, generation), four services, 30 days up to now, Korean input and output.
# events_full_nomv is the same DDL without views: the first 1.5M rows go into both, in three inserts each,
# to time what the views add to an insert. Langfuse's own tables are not touched.
#
# Each query runs three times (query cache off); results/05-bench.tsv gets the median duration and the
# read_rows / read_bytes of that run from system.query_log.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
M="${1:-6}"
B=lab_langfuse_ch_mv_bench
ch "DROP DATABASE IF EXISTS $B SYNC"
ch "CREATE DATABASE $B"
for t in events_full_mv events_full_nomv; do ch "CREATE TABLE $B.$t AS default.events_full"; done
for t in obs_hourly_by_service obs_hourly_by_tag review_observations; do
  ch "CREATE TABLE $B.$t AS $LAB_DB.$t"
  ch "CREATE MATERIALIZED VIEW $B.${t}_mv TO $B.$t AS $(view_select "$t" 1 "$B.events_full_mv")"
done

gen() {   # gen <offset> <rows>: SELECT of synthetic events_full rows number <offset> … <offset>+<rows>-1
  cat <<SQL
WITH number AS n, intDiv(n, 3) AS k, n % 3 AS i,
     ['support-chat', 'doc-summary', 'policy-qa', 'voc-classify'][1 + k % 4] AS svc,
     ['cx', 'ops', 'compliance', 'cx'][1 + k % 4] AS team,
     ['상담-응답', '문서-요약', '규정-질의', 'VOC-분류'][1 + k % 4] AS tname,
     ['gpt-4o-mini', 'gpt-4o', 'gpt-4o-mini', 'claude-haiku-4-5'][1 + k % 4] AS mdl,
     sipHash64(k) AS h,
     now64(6) - toIntervalMillisecond(h % (30 * 86400000)) AS t0,
     toUInt32(50 + (sipHash64(n, 'lat') % 1500)) AS lat,
     (h % 100) < 4 AS is_err,
     (h % 100) < 12 AS review,
     toUInt64(300 + sipHash64(n, 'in') % 1500) AS itok, toUInt64(30 + sipHash64(n, 'out') % 400) AS otok
SELECT
    'llm-observability' AS project_id,
    lower(hex(MD5(toString(k)))) AS trace_id,
    substring(lower(hex(MD5(concat(toString(k), '-', toString(i))))), 1, 16) AS span_id,
    if(i = 0, '', substring(lower(hex(MD5(concat(toString(k), '-0')))), 1, 16)) AS parent_span_id,
    t0 + toIntervalMillisecond(i * 20) AS start_time,
    t0 + toIntervalMillisecond(i * 20 + lat) AS end_time,
    [tname, '문서-검색', '답변-생성'][i + 1] AS name,
    if(i = 2, 'GENERATION', 'SPAN') AS type,
    tname AS trace_name,
    concat('emp-', leftPad(toString(h % 500), 3, '0')) AS user_id,
    concat(svc, '-', toString(intDiv(k, 4))) AS session_id,
    arrayConcat([concat('svc:', svc), concat('team:', team), if(h % 5 = 0, 'env:staging', 'env:production'), '$LAB_TAG'],
                if(review, ['review:needed'], [])) AS tags,
    if(i = 2 AND is_err, 'ERROR', 'DEFAULT') AS level,
    if(i = 2, mdl, '') AS provided_model_name,
    if(i = 2, map('input', itok, 'output', otok, 'total', itok + otok), map()) AS usage_details,
    if(i = 2, map('input', toDecimal64(itok * 0.00000015, 12), 'output', toDecimal64(otok * 0.0000006, 12),
                  'total', toDecimal64(itok * 0.00000015 + otok * 0.0000006, 12)), map()) AS cost_details,
    concat('{"질문":"', ['적금을 만기 전에 해지하면 이자는 어떻게 되나요?', '다음 회의록을 세 줄로 요약해 주세요.',
           '개인정보 보관 기간이 지난 데이터는 언제까지 파기해야 하나요?', '앱 업데이트 후 로그인이 계속 풀려요.'][1 + k % 4],
           ' 요청 번호 ', toString(k), '"}') AS input,
    if(i = 2 AND is_err, '', concat('"', ['중도해지 이율이 적용됩니다.', '1) 절차 개정 2) 배치 조정 3) 다음 점검은 1월.',
           '보관 기간이 끝나면 지체 없이 파기합니다.', '분류: 앱 오류 / 긴급도: 중'][1 + k % 4], '"')) AS output,
    ['batch', 'team'] AS metadata_names, ['bench', team] AS metadata_values,
    'otel' AS source, svc AS service_name,
    start_time AS event_ts, start_time AS created_at, start_time AS updated_at, toUInt8(0) AS is_deleted
FROM numbers($1, $2)
SQL
}
COLS="project_id, trace_id, span_id, parent_span_id, start_time, end_time, name, type, trace_name, user_id, session_id,
      tags, level, provided_model_name, usage_details, cost_details, input, output, metadata_names, metadata_values,
      source, service_name, event_ts, created_at, updated_at, is_deleted"
OUT="$RESULTS/05-bench.tsv"
printf 'date\tstep\tduration_ms\tread_rows\tread_bytes\tresult_rows\n' > "$OUT"
stamp=$(date -u +%FT%TZ)
C=500000   # rows per INSERT (one insert of 1M rows took 3.8 GiB of memory here: the text indexes)
# Insert cost of the views: three rounds of C rows into each table, alternating, median duration.
for r in 1 2 3; do
  for t in nomv mv; do chq "05-$$-insert-$t-$r" "INSERT INTO $B.events_full_$t ($COLS) $(gen $(((r - 1) * C)) $C)"; done
done
for t in nomv mv; do
  for r in 1 2 3; do qlog "05-$$-insert-$t-$r"; done | sort -n | sed -n 2p |
    sed "s/^/$stamp\tinsert $C rows, $( [[ $t == mv ]] && echo 'with the 3 views' || echo 'no views') (median of 3)\t/" >> "$OUT"
done
for ((o = 3 * C; o < M * 1000000; o += C)); do ch "INSERT INTO $B.events_full_mv ($COLS) $(gen $o $C)"; done
ch "DROP TABLE $B.events_full_nomv SYNC"
ch "OPTIMIZE TABLE $B.obs_hourly_by_service FINAL"; ch "OPTIMIZE TABLE $B.obs_hourly_by_tag FINAL"
ch "SELECT table, sum(rows) AS rows, formatReadableSize(sum(data_compressed_bytes)) AS compressed
    FROM system.parts WHERE database = '$B' AND active GROUP BY table ORDER BY table" PrettyCompactMonoBlock | tee "$RESULTS/05-sizes.txt"

run() {   # run <step name> <sql>: three runs, keep the median duration's query_log row
  local name="$1" sql="$2" i rows=()
  for i in 1 2 3; do chq "05-$$-${name// /_}-$i" "$sql SETTINGS use_query_cache = 0" > /dev/null; done
  for i in 1 2 3; do rows+=("$(qlog "05-$$-${name// /_}-$i")"); done
  printf '%s\n' "${rows[@]}" | sort -n | sed -n 2p | sed "s/^/$stamp\t$name\t/" >> "$OUT"
}
P="project_id = 'llm-observability'"
run "Q1 raw: per service, 7 days" "SELECT service_name, uniqExact(trace_id) traces, count() observations,
  sum(usage_details['total']) tokens, sum(cost_details['total']) cost,
  quantileTDigestIf(0.95)(toUInt32(dateDiff('millisecond', start_time, end_time)), type = 'GENERATION') p95_ms
  FROM $B.events_full_mv WHERE $P AND start_time >= now() - INTERVAL 7 DAY AND has(tags, '$LAB_TAG') GROUP BY service_name ORDER BY service_name"
run "Q1 view: per service, 7 days" "SELECT service_name, sum(traces) traces, sum(observations) observations,
  sum(total_tokens) tokens, sum(cost_usd) cost,
  quantilesTDigestMergeIf(0.5, 0.95, 0.99)(latency_ms, type = 'GENERATION')[2] p95_ms
  FROM $B.obs_hourly_by_service WHERE $P AND hour >= now() - INTERVAL 7 DAY GROUP BY service_name ORDER BY service_name"
run "Q2 raw: cost per team tag per day, 30 days" "SELECT toDate(start_time) d, tag, sum(cost_details['total']) cost
  FROM $B.events_full_mv ARRAY JOIN tags AS tag WHERE $P AND start_time >= now() - INTERVAL 30 DAY AND has(tags, '$LAB_TAG')
  AND tag LIKE 'team:%' GROUP BY d, tag ORDER BY d, tag"
run "Q2 view: cost per team tag per day, 30 days" "SELECT toDate(hour) d, tag, sum(cost_usd) cost
  FROM $B.obs_hourly_by_tag WHERE $P AND hour >= now() - INTERVAL 30 DAY AND tag LIKE 'team:%' GROUP BY d, tag ORDER BY d, tag"
run "Q3 raw: review:needed observations, 24 h, with input" "SELECT trace_id, span_id, name, level, input, output
  FROM $B.events_full_mv WHERE $P AND start_time >= now() - INTERVAL 1 DAY AND has(tags, 'review:needed') FORMAT Null"
run "Q3 copy: review:needed observations, 24 h, with input" "SELECT trace_id, span_id, name, level, input, output
  FROM $B.review_observations WHERE $P AND start_time >= now() - INTERVAL 1 DAY FORMAT Null"
# Same answer from raw and view (Q1), as a last check on the copy.
a=$(ch "SELECT service_name, uniqExact(trace_id), count(), sum(cost_details['total']) FROM $B.events_full_mv GROUP BY 1 ORDER BY 1")
b=$(ch "SELECT service_name, sum(traces), sum(observations), sum(cost_usd) FROM $B.obs_hourly_by_service GROUP BY 1 ORDER BY 1")
check "bench: raw and view agree (traces, observations, cost per service)" "$a" "$b"
column -t -s $'\t' "$OUT"
[[ $fail -eq 0 ]]
