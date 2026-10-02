-- ════════════════════════════════════════════════════════════════════════════
-- 08-verify-masking.sql
-- Prove SERVER-SIDE DATA MASKING (an EE feature) worked — using ClickHouse.
--
-- 08-generate-pii-traces.py sent traces containing four sentinel secrets, in the
-- model input / output AND in metadata. With the masking sidecar active, Langfuse's
-- worker redacted them BEFORE persisting to ClickHouse. So the raw sentinels must be
-- ABSENT from events_full — the full-payload table, where input, output and metadata
-- are not truncated — and the [REDACTED_*] placeholders must be PRESENT.
--
-- The LAST row is the verdict: PASS only if the pii-demo rows landed AND some of
-- them carry a [REDACTED_*] placeholder AND no sentinel leaked anywhere; otherwise
-- FAIL. An empty table therefore fails (nothing landed, nothing was masked), which
-- is what stops a vacuous "0 leaks" from passing. 08-ee-data-masking.sh exits 1 on FAIL.
--
-- Run:
--   docker exec -i langfuse-hols-clickhouse-1 clickhouse-client \
--     -u clickhouse --password clickhouse --multiquery < 08-verify-masking.sql
--
-- The metadata is stored as two parallel arrays (metadata_names / metadata_values), so
-- a secret in a metadata VALUE is found with arrayExists() over metadata_values.
-- ════════════════════════════════════════════════════════════════════════════

-- 0) Did the PII-demo traces land at all? (sanity: should be > 0)
SELECT 'pii-demo rows present' AS check, count() AS n
FROM default.events_full FINAL
WHERE is_deleted = 0 AND has(tags, 'pii-demo');

-- 1) LEAK CHECK — how many rows still contain each raw secret in input, output or
--    metadata? EXPECT ALL ZERO. (All rows, not only pii-demo: a leak anywhere counts.)
SELECT '── events_full: raw-secret leak counts (want all 0) ──' AS section;
SELECT
    countIf(position(input, '0xDEADBEEF01') > 0 OR position(output, '0xDEADBEEF01') > 0
         OR arrayExists(v -> position(v, '0xDEADBEEF01') > 0, metadata_values))      AS leaked_api_key,
    countIf(position(input, '4111 1111 1111 1111') > 0 OR position(output, '4111 1111 1111 1111') > 0
         OR arrayExists(v -> position(v, '4111 1111 1111 1111') > 0, metadata_values)) AS leaked_card,
    countIf(position(input, 'victim@secret-corp.test') > 0 OR position(output, 'victim@secret-corp.test') > 0
         OR arrayExists(v -> position(v, 'victim@secret-corp.test') > 0, metadata_values)) AS leaked_email,
    countIf(position(input, '900101-1234567') > 0 OR position(output, '900101-1234567') > 0
         OR arrayExists(v -> position(v, '900101-1234567') > 0, metadata_values))    AS leaked_rrn
FROM default.events_full FINAL
WHERE is_deleted = 0;

-- 2) POSITIVE CHECK — the redaction placeholders DID make it in. EXPECT > 0.
SELECT '── pii-demo rows carrying a [REDACTED_*] placeholder (want > 0) ──' AS section;
SELECT
    countIf(position(input, '[REDACTED_') > 0 OR position(output, '[REDACTED_') > 0)   AS masked_payload_rows,
    countIf(arrayExists(v -> position(v, '[REDACTED_') > 0, metadata_values))          AS masked_metadata_rows
FROM default.events_full FINAL
WHERE is_deleted = 0 AND has(tags, 'pii-demo');

-- 3) EYEBALL IT — a few masked rows, secrets swapped for placeholders. The metadata
--    keys raw_email / raw_rrn were set on the trace, leaked_key on the generation.
SELECT '── sample masked observation payloads ──' AS section;
SELECT
    name,
    substring(input,  1, 220) AS input_sample,
    substring(output, 1, 220) AS output_sample,
    metadata_values[indexOf(metadata_names, 'raw_email')]   AS meta_raw_email,
    metadata_values[indexOf(metadata_names, 'raw_rrn')]     AS meta_raw_rrn,
    metadata_values[indexOf(metadata_names, 'leaked_key')]  AS meta_leaked_key
FROM default.events_full FINAL
WHERE is_deleted = 0 AND has(tags, 'pii-demo')
  AND (position(input, '[REDACTED_') > 0 OR position(output, '[REDACTED_') > 0)
LIMIT 3
FORMAT Vertical;

-- 4) VERDICT — one row, the last output of this file. PASS only if all three hold:
--    pii-demo rows > 0, masked pii-demo rows > 0, and every leak count = 0.
SELECT
    'verdict'                                                              AS check,
    multiIf(pii_rows = 0, 'FAIL', masked_rows = 0, 'FAIL', leaks > 0, 'FAIL', 'PASS') AS verdict,
    pii_rows,
    masked_rows,
    leaks
FROM (
    SELECT
        countIf(has(tags, 'pii-demo'))                                                    AS pii_rows,
        countIf(has(tags, 'pii-demo')
                AND (position(input, '[REDACTED_') > 0 OR position(output, '[REDACTED_') > 0
                     OR arrayExists(v -> position(v, '[REDACTED_') > 0, metadata_values))) AS masked_rows,
        countIf(multiSearchAny(input, ['0xDEADBEEF01', '4111 1111 1111 1111', 'victim@secret-corp.test', '900101-1234567'])
             OR multiSearchAny(output, ['0xDEADBEEF01', '4111 1111 1111 1111', 'victim@secret-corp.test', '900101-1234567'])
             OR arrayExists(v -> multiSearchAny(v, ['0xDEADBEEF01', '4111 1111 1111 1111', 'victim@secret-corp.test', '900101-1234567']),
                            metadata_values))                                              AS leaks
    FROM default.events_full FINAL
    WHERE is_deleted = 0
);
