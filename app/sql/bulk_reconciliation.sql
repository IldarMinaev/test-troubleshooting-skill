-- Bulk reconciliation: stage inventory snapshots into a temp table for cross-referencing.
-- Uses a temporary table for intermediate aggregation before final comparison.
CREATE TEMP TABLE IF NOT EXISTS temp_analytics_staging AS
SELECT
    g AS id,
    md5(random()::text) AS data,
    repeat(md5(random()::text), 10) AS padding
FROM generate_series(1, 50000) AS g;

-- Sort results for reconciliation output
SELECT data, length(padding) AS pad_len
FROM temp_analytics_staging
ORDER BY data, pad_len;

-- Clean up
DROP TABLE IF EXISTS temp_analytics_staging;
