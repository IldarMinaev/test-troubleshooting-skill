-- Create a large temporary table for analytics staging and sorting.
-- Temp tables bypass shared_buffers and can spill to disk when work_mem is exceeded.
CREATE TEMP TABLE IF NOT EXISTS temp_analytics_staging AS
SELECT
    g AS id,
    md5(random()::text) AS data,
    repeat(md5(random()::text), 10) AS padding
FROM generate_series(1, 50000) AS g;

-- Force a sort that spills to temp files when work_mem is exceeded
SELECT data, length(padding) AS pad_len
FROM temp_analytics_staging
ORDER BY data, pad_len;

-- Clean up
DROP TABLE IF EXISTS temp_analytics_staging;
