-- ════════════════════════════════════════════════════════════════════════════
-- 08-verify-masking.sql
-- Prove SERVER-SIDE DATA MASKING (an EE feature) worked — using ClickHouse.
--
-- 08-generate-pii-traces.py sent traces containing four sentinel secrets. With
-- the masking sidecar active, Langfuse's worker redacted them BEFORE persisting
-- to ClickHouse. So the raw sentinels must be ABSENT from traces/observations,
-- and the [REDACTED_*] placeholders must be PRESENT.
--
-- Run:
--   docker compose exec -T clickhouse clickhouse-client \
--     -u clickhouse --password clickhouse --multiquery < 08-verify-masking.sql
-- ════════════════════════════════════════════════════════════════════════════

-- 0) Did the PII-demo traces land at all? (sanity: should be > 0)
SELECT 'pii-demo traces present' AS check, count() AS n
FROM default.traces FINAL
WHERE is_deleted = 0 AND has(tags, 'pii-demo');

-- 1) LEAK CHECK — how many rows still contain each raw secret? EXPECT ALL ZERO.
--    input/output are String (JSON) columns; toString() is defensive.
SELECT '── observations: raw-secret leak counts (want all 0) ──' AS section;
SELECT
    countIf(position(toString(input), '0xDEADBEEF01') > 0
         OR position(toString(output), '0xDEADBEEF01') > 0)      AS leaked_api_key,
    countIf(position(toString(input), '4111 1111 1111 1111') > 0
         OR position(toString(output), '4111 1111 1111 1111') > 0) AS leaked_card,
    countIf(position(toString(input), 'victim@secret-corp.test') > 0
         OR position(toString(output), 'victim@secret-corp.test') > 0) AS leaked_email,
    countIf(position(toString(input), '900101-1234567') > 0
         OR position(toString(output), '900101-1234567') > 0)    AS leaked_rrn
FROM default.observations FINAL
WHERE is_deleted = 0;

SELECT '── traces: raw-secret leak counts (want all 0) ──' AS section;
SELECT
    countIf(position(toString(input), '0xDEADBEEF01') > 0
         OR position(toString(output), '0xDEADBEEF01') > 0)      AS leaked_api_key,
    countIf(position(toString(input), '4111 1111 1111 1111') > 0
         OR position(toString(output), '4111 1111 1111 1111') > 0) AS leaked_card,
    countIf(position(toString(input), 'victim@secret-corp.test') > 0
         OR position(toString(output), 'victim@secret-corp.test') > 0) AS leaked_email,
    countIf(position(toString(input), '900101-1234567') > 0
         OR position(toString(output), '900101-1234567') > 0)    AS leaked_rrn
FROM default.traces FINAL
WHERE is_deleted = 0;

-- 2) POSITIVE CHECK — the redaction placeholders DID make it in. EXPECT > 0.
SELECT '── rows carrying a [REDACTED_*] placeholder (want > 0) ──' AS section;
SELECT
    countIf(position(toString(input), '[REDACTED_') > 0
         OR position(toString(output), '[REDACTED_') > 0)        AS masked_observation_rows
FROM default.observations FINAL
WHERE is_deleted = 0;

-- 3) EYEBALL IT — a few masked payloads, secrets swapped for placeholders.
SELECT '── sample masked observation payloads ──' AS section;
SELECT
    name,
    substring(toString(input),  1, 220) AS input_sample,
    substring(toString(output), 1, 220) AS output_sample
FROM default.observations FINAL
WHERE is_deleted = 0
  AND (position(toString(input), '[REDACTED_') > 0 OR position(toString(output), '[REDACTED_') > 0)
LIMIT 3
FORMAT Vertical;
