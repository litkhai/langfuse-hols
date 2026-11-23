-- 01-schema.sql — the lab's own objects, all in database lab_langfuse_ch_vector.
-- Langfuse's tables in `default` are only read, never changed.
-- Run: .venv-vector/bin/python labs/v4/langfuse-ch-vector/01-setup.py

CREATE DATABASE IF NOT EXISTS lab_langfuse_ch_vector;

-- One row per embedded text: the input and the output of a root observation (= the trace).
-- Plain MergeTree: 03-embed.py writes each (span_id, kind) once, so no FINAL is needed and
-- the vector similarity index stays usable (ORDER BY cosineDistance(...) LIMIT k).
CREATE TABLE IF NOT EXISTS lab_langfuse_ch_vector.embeddings
(
    project_id     String,
    trace_id       String,
    span_id        String,
    kind           LowCardinality(String),           -- 'input' | 'output'
    name           String,                           -- observation name
    level          LowCardinality(String),           -- DEFAULT | WARNING | ERROR
    status_message String,
    start_time     DateTime64(6),
    event_ts       DateTime64(6),                    -- Langfuse's version column, the watermark
    text           String,
    model          LowCardinality(String),
    embedded_at    DateTime64(3) DEFAULT now64(3),
    vec            Array(Float32),
    CONSTRAINT dim CHECK length(vec) = 1024,
    INDEX vec_hnsw vec TYPE vector_similarity('hnsw', 'cosineDistance', 1024)
)
ENGINE = MergeTree
ORDER BY (project_id, kind, trace_id, span_id);

-- How far 03-embed.py has read events_full (latest row wins).
CREATE TABLE IF NOT EXISTS lab_langfuse_ch_vector.watermark
(
    pipeline   String,
    event_ts   DateTime64(6),
    rows_read  UInt64,
    rows_added UInt64,
    run_at     DateTime64(3) DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(run_at)
ORDER BY pipeline;

-- Topic of each trace from 05-topics.py (one run = one clustering).
CREATE TABLE IF NOT EXISTS lab_langfuse_ch_vector.topics
(
    run_id       String,
    trace_id     String,
    topic        UInt16,
    topic_label  String,                             -- the wording closest to the centroid
    distance     Float32,                            -- cosine distance to the centroid
    run_at       DateTime64(3) DEFAULT now64(3)
)
ENGINE = MergeTree
ORDER BY (run_id, topic, trace_id);

-- Query vectors of free-text searches (04-similar.py), so plain SQL can reuse them.
CREATE TABLE IF NOT EXISTS lab_langfuse_ch_vector.queries
(
    name   String,
    text   String,
    vec    Array(Float32),
    run_at DateTime64(3) DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(run_at)
ORDER BY name;
