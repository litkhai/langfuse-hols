-- 05-topics.sql — per topic of the latest 05-topics.py run: traces, error rate, most common error.
SELECT
    t.topic                                                          AS topic,
    any(t.topic_label)                                               AS closest_to_centroid,
    count()                                                          AS traces,
    round(countIf(e.level = 'ERROR') / count(), 2)                   AS error_rate,
    topK(1)(if(e.status_message = '', NULL, e.status_message))[1]    AS top_error
FROM lab_langfuse_ch_vector.topics AS t
INNER JOIN lab_langfuse_ch_vector.embeddings AS e ON e.trace_id = t.trace_id AND e.kind = 'input'
WHERE t.run_id = (SELECT max(run_id) FROM lab_langfuse_ch_vector.topics)
GROUP BY t.topic
ORDER BY error_rate DESC, traces DESC
