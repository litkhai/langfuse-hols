#!/usr/bin/env bash
# 01-schema.sh — where Langfuse v4 keeps observations, read from the live ClickHouse (not from memory).
#
# Prints: the tables Langfuse created and their engines, the last applied migration, the engine and keys of
# events_full, the columns the views of 03 read, Langfuse's own events_core_mv (events_full → events_core,
# input/output cut to 200 characters), and how a trace looks there (the root observation, parent_span_id = '').
# Output: results/01-schema.txt.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
exec > >(tee "$RESULTS/01-schema.txt")
echo "# 01-schema.sh, $(date -u +%FT%TZ), ClickHouse $(ch 'SELECT version()'), Langfuse image $(docker inspect -f '{{.Config.Image}}' "$LF_PROJECT-langfuse-web-1" 2>/dev/null || echo '?')"
echo; echo "## Tables in database default"
ch "SELECT name, engine, total_rows FROM system.tables WHERE database = 'default' ORDER BY engine, name" PrettyCompactMonoBlock
echo "last migration applied: $(ch "SELECT max(version) FROM default.schema_migrations WHERE dirty = 0")"
echo; echo "## events_full"
ch "SELECT engine_full FROM system.tables WHERE database = 'default' AND name = 'events_full'" TSVRaw | sed 's/ SETTINGS.*//'
echo "columns: $(ch "SELECT count() FROM system.columns WHERE database = 'default' AND table = 'events_full'")"
ch "SELECT name, type, default_kind, default_expression FROM system.columns
    WHERE database = 'default' AND table = 'events_full'
      AND name IN ('project_id','trace_id','span_id','parent_span_id','start_time','end_time','type','name','trace_name',
                   'service_name','tags','level','provided_model_name','usage_details','cost_details','total_cost',
                   'input','output','created_at','event_ts','is_deleted')
    ORDER BY position" PrettyCompactMonoBlock
echo; echo "## Materialized views Langfuse ships"
ch "SELECT name, engine FROM system.tables
    WHERE database = 'default' AND engine = 'MaterializedView'" PrettyCompactMonoBlock
ch "SELECT create_table_query FROM system.tables WHERE database = 'default' AND name = 'events_core_mv'" TSVRaw \
  | grep -oE 'TO default\.[a-z_]+|leftUTF8\([a-z_]+, 200\)|arrayMap\(v -> leftUTF8\(v, 200\), [a-z_]+\)|FROM default\.[a-z_]+' | sort -u
echo; echo "## One trace of this lab, as rows of events_full"
ch "SELECT parent_span_id = '' AS root, type, name, service_name, provided_model_name AS model,
           usage_details['total'] AS tokens, cost_details['total'] AS cost, dateDiff('millisecond', start_time, end_time) AS ms, tags
    FROM default.events_full
    WHERE trace_id = (SELECT trace_id FROM default.events_full WHERE has(tags, '$LAB_TAG') AND service_name = 'policy-qa' AND NOT has(tags, 'review:needed')
                      AND parent_span_id = '' ORDER BY start_time LIMIT 1)
    ORDER BY start_time" PrettyCompactMonoBlock
echo; echo "## Rows of this lab by service (OpenTelemetry service.name)"
ch "SELECT service_name, count() AS observations, uniqExact(trace_id) AS traces FROM default.events_full
    WHERE has(tags, '$LAB_TAG') GROUP BY service_name ORDER BY service_name" PrettyCompactMonoBlock
