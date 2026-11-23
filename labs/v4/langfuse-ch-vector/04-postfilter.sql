-- 04-postfilter.sql — the same top-10 (WHERE kind = 'input') four ways, for the free-text query
-- that 04-similar.py stored in lab_langfuse_ch_vector.queries. Through the HNSW index the WHERE
-- is applied after the index returned its 10 nearest rows, so fewer than 10 rows come back.
WITH (SELECT vec FROM lab_langfuse_ch_vector.queries WHERE name = 'free-text' ORDER BY run_at DESC LIMIT 1) AS q
SELECT * FROM (
SELECT '1 index, default' AS how, count() AS rows_returned, round(max(d), 3) AS farthest
FROM (SELECT cosineDistance(vec, q) AS d FROM lab_langfuse_ch_vector.embeddings WHERE kind = 'input'
      ORDER BY cosineDistance(vec, q) LIMIT 10)
UNION ALL
SELECT '2 index, fetch_multiplier = 4', count(), round(max(d), 3)
FROM (SELECT cosineDistance(vec, q) AS d FROM lab_langfuse_ch_vector.embeddings WHERE kind = 'input'
      ORDER BY cosineDistance(vec, q) LIMIT 10 SETTINGS vector_search_index_fetch_multiplier = 4)
UNION ALL
SELECT '3 prefilter', count(), round(max(d), 3)
FROM (SELECT cosineDistance(vec, q) AS d FROM lab_langfuse_ch_vector.embeddings WHERE kind = 'input'
      ORDER BY cosineDistance(vec, q) LIMIT 10 SETTINGS vector_search_filter_strategy = 'prefilter')
UNION ALL
SELECT '4 exact', count(), round(max(d), 3)
FROM (SELECT cosineDistance(vec, q) AS d FROM lab_langfuse_ch_vector.embeddings WHERE kind = 'input'
      ORDER BY cosineDistance(vec, q) LIMIT 10 SETTINGS use_skip_indexes = 0)
)
ORDER BY how
