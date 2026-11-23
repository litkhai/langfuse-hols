-- 04-similar.sql — the ten past traces closest to the newest failing one, with how each ended.
-- Self-contained (no query parameters), so it can be pasted into the ClickHouse Play UI
-- (http://localhost:8123/play). 04-similar.py runs the same query for a given trace id.
WITH
    (SELECT trace_id FROM lab_langfuse_ch_vector.embeddings
     WHERE kind = 'input' AND level = 'ERROR' ORDER BY start_time DESC LIMIT 1) AS failing,
    (SELECT vec FROM lab_langfuse_ch_vector.embeddings
     WHERE kind = 'input' AND trace_id = failing) AS q
SELECT
    round(cosineDistance(i.vec, q), 3) AS distance,
    i.text                             AS question,
    i.level                            AS level,
    i.status_message                   AS status_message,
    leftUTF8(o.text, 40)               AS answer,
    i.trace_id                         AS trace_id
FROM lab_langfuse_ch_vector.embeddings AS i
LEFT JOIN
(
    SELECT trace_id, text FROM lab_langfuse_ch_vector.embeddings WHERE kind = 'output'
) AS o USING (trace_id)
WHERE i.kind = 'input' AND i.trace_id != failing
ORDER BY cosineDistance(i.vec, q)
LIMIT 10
SETTINGS use_skip_indexes = 0
