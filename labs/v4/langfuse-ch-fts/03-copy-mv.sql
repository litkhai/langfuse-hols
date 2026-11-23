-- 03-copy-mv.sql — on the shared stack's ClickHouse (Langfuse's own server).
-- A search copy of Langfuse's observations in database lab_langfuse_ch_fts, kept current by a
-- materialized view on default.events_full. Langfuse's own tables are only read, never altered.
--
-- Why a copy and not ALTER TABLE default.events_full ADD INDEX …:
--   * events_full is Langfuse's schema. Its migrations create and change it (0039 creates it with
--     its own text indexes); an index added by hand is not in those migrations, is not known to the
--     next migration, and is rebuilt on every merge of the busiest table of the stack.
--   * The Python SDK stores dict/list inputs and outputs as JSON with \uXXXX escapes, so Korean in
--     events_full.input reads "\ub300\ucd9c", not "대출". No tokenizer sees Hangul there. The copy
--     stores the decoded text.
--   * The copy can hold only what search needs (project, trace, span, time, tags, text) and only
--     the projects or tags you choose — here the traces tagged lab:langfuse-ch-fts.
--
-- Run: python3 labs/v4/langfuse-ch-fts/lablib.py LF labs/v4/langfuse-ch-fts/03-copy-mv.sql

CREATE DATABASE IF NOT EXISTS lab_langfuse_ch_fts;

DROP VIEW IF EXISTS lab_langfuse_ch_fts.events_text_mv;

DROP TABLE IF EXISTS lab_langfuse_ch_fts.events_text;

-- Decoded text: a JSON document goes through JSONExtractString on a wrapper object, which returns a
-- non-string value as JSON text with the \uXXXX escapes decoded (seen on 26.8.22.13 and 26.10.10.3,
-- 04-tokenizers.py checks it); a plain string is kept as it is.
CREATE TABLE lab_langfuse_ch_fts.events_text
(
    project_id  String,
    trace_id    String,
    span_id     String,
    start_time  DateTime64(6),
    name        String,
    type        LowCardinality(String),
    tags        Array(String),
    input_text  String CODEC(ZSTD(3)),
    output_text String CODEC(ZSTD(3)),
    event_ts    DateTime64(6),
    is_deleted  UInt8,
    -- For Korean: every two characters, so 대출 is a token inside 대출을 and 주택담보대출.
    -- (One text index per expression: ClickHouse rejects a second one on lower(input_text).
    -- 06-bench.py compares tokenizers on separate tables.)
    INDEX idx_in_ng2   lower(input_text)  TYPE text(tokenizer = ngrams(2)),
    INDEX idx_out_ng2  lower(output_text) TYPE text(tokenizer = ngrams(2))
)
ENGINE = ReplacingMergeTree(event_ts, is_deleted)
PARTITION BY toYYYYMM(start_time)
ORDER BY (project_id, toDate(start_time), trace_id, span_id);

CREATE MATERIALIZED VIEW lab_langfuse_ch_fts.events_text_mv TO lab_langfuse_ch_fts.events_text AS
SELECT
    project_id, trace_id, span_id, start_time, name, type, tags,
    if(isValidJSON(input),  JSONExtractString(concat('{"v":', input,  '}'), 'v'), input)  AS input_text,
    if(isValidJSON(output), JSONExtractString(concat('{"v":', output, '}'), 'v'), output) AS output_text,
    event_ts, is_deleted
FROM default.events_full
WHERE has(tags, 'lab:langfuse-ch-fts');

-- Backfill what was there before the view existed. Rows that arrive between CREATE MATERIALIZED VIEW
-- and this INSERT land twice; ReplacingMergeTree collapses them on merge (same sorting key).
INSERT INTO lab_langfuse_ch_fts.events_text
SELECT
    project_id, trace_id, span_id, start_time, name, type, tags,
    if(isValidJSON(input),  JSONExtractString(concat('{"v":', input,  '}'), 'v'), input),
    if(isValidJSON(output), JSONExtractString(concat('{"v":', output, '}'), 'v'), output),
    event_ts, is_deleted
FROM default.events_full
WHERE has(tags, 'lab:langfuse-ch-fts');

OPTIMIZE TABLE lab_langfuse_ch_fts.events_text FINAL;

SELECT count() AS rows, uniqExact(trace_id) AS traces, countIf(input_text LIKE '%대출%') AS input_with_daechul
FROM lab_langfuse_ch_fts.events_text
FORMAT PrettyCompactMonoBlock;
