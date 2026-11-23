Langfuse v4 data in ClickHouse (database `default`), for the clickhouse MCP tools:
- Every observation (span, generation, event) is a row of `events_full` (all columns) and of `events_core` (the same rows, fewer columns). A trace is the rows with one `trace_id`; its root row has `parent_span_id = ''`.
- The tables `traces` and `observations` come from Langfuse v3 and are empty in v4. Do not use them.
- The tables are ReplacingMergeTree: read with FINAL and `is_deleted = 0`.
- Trace attributes are on every row: `trace_name`, `user_id`, `session_id`, `tags`, `metadata_names` / `metadata_values`.
- Generations: `provided_model_name`, `usage_details['input']` / `['output']`, `total_cost` (USD), `prompt_name`, `prompt_version`, `level` (`'ERROR'` = failed), `status_message`. Duration = `end_time - start_time`.
- This user cannot read `input` or `output` (column grant); `input_length` / `output_length` are readable.
