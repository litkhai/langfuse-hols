#!/usr/bin/env bash
# 04-check.sh — do the views agree with events_full? Exit 1 on any FAIL.
#
# The reference is events_full FINAL (one row per observation, the way Langfuse reads it) with the views'
# own filter (lab tag, is_deleted = 0). Counts, tokens and cost must match exactly; latency p95 is shown
# next to each other (t-digest states merge to an estimate, not to the exact value).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
W="has(tags, '$LAB_TAG') AND is_deleted = 0"
echo "# 04-check.sh, $(date -u +%FT%TZ): the per-service rollup now"
ch "SELECT service_name, sum(traces) AS traces, sum(observations) AS observations, sum(errors) AS errors,
    sum(total_tokens) AS tokens, round(sum(cost_usd), 4) AS cost_usd,
    round(quantilesTDigestMergeIf(0.5, 0.95, 0.99)(latency_ms, type = 'GENERATION')[2]) AS gen_p95_ms
    FROM $LAB_DB.obs_hourly_by_service GROUP BY service_name ORDER BY service_name" PrettyCompactMonoBlock

raw_svc=$(ch "SELECT service_name, sum(c), sum(e), sum(tok), sum(cost) FROM (
  SELECT service_name, count() c, countIf(level='ERROR') e, sum(usage_details['total']) tok, sum(cost_details['total']) cost
  FROM default.events_full FINAL WHERE $W GROUP BY service_name) GROUP BY 1 ORDER BY 1")
mv_svc=$(ch "SELECT service_name, sum(observations), sum(errors), sum(total_tokens), sum(cost_usd)
  FROM $LAB_DB.obs_hourly_by_service GROUP BY 1 ORDER BY 1")
check "per service: observations, errors, tokens, cost" "$raw_svc" "$mv_svc"

raw_tr=$(ch "SELECT service_name, uniqExact(trace_id) FROM default.events_full FINAL WHERE $W GROUP BY 1 ORDER BY 1")
mv_tr=$(ch "SELECT service_name, sum(traces) FROM $LAB_DB.obs_hourly_by_service GROUP BY 1 ORDER BY 1")
check "per service: traces (distinct trace_id vs root observations)" "$raw_tr" "$mv_tr"

raw_tag=$(ch "SELECT tag, count(), uniqExact(trace_id), sum(usage_details['total']), sum(cost_details['total'])
  FROM default.events_full FINAL ARRAY JOIN arrayFilter(t -> t != '$LAB_TAG', tags) AS tag WHERE $W GROUP BY 1 ORDER BY 1")
mv_tag=$(ch "SELECT tag, sum(observations), sum(traces), sum(total_tokens), sum(cost_usd)
  FROM $LAB_DB.obs_hourly_by_tag GROUP BY 1 ORDER BY 1")
check "per tag: observations, traces, tokens, cost" "$raw_tag" "$mv_tag"

raw_rev=$(ch "SELECT count(), uniqExact(trace_id), sum(length(input) + length(output)) FROM default.events_full FINAL
  WHERE $W AND has(tags, 'review:needed')")
mv_rev=$(ch "SELECT count(), uniqExact(trace_id), sum(length(input) + length(output)) FROM $LAB_DB.review_observations FINAL")
check "review copy (FINAL): rows, traces, input+output bytes" "$raw_rev" "$mv_rev"
mv_rev_nofinal=$(ch "SELECT count() FROM $LAB_DB.review_observations")
echo "INFO  review copy without FINAL: $mv_rev_nofinal rows"

echo "INFO  latency p95 of GENERATION observations (ms), raw quantileExact vs view t-digest:"
ch "SELECT r.service_name, r.p95_exact, m.p95_tdigest FROM
  (SELECT service_name, quantileExact(0.95)(toUInt32(greatest(dateDiff('millisecond', start_time, end_time), 0))) p95_exact
   FROM default.events_full FINAL WHERE $W AND type = 'GENERATION' AND end_time IS NOT NULL GROUP BY 1) r
  JOIN (SELECT service_name, round(quantilesTDigestMerge(0.5, 0.95, 0.99)(latency_ms)[2]) p95_tdigest
   FROM $LAB_DB.obs_hourly_by_service WHERE type = 'GENERATION' GROUP BY 1) m USING service_name ORDER BY 1" PrettyCompactMonoBlock
echo "$pass PASS, $fail FAIL"
[[ $fail -eq 0 ]]
