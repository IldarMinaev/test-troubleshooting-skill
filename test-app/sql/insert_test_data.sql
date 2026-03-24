-- Bulk insert: 100 rows per batch, ~1KB each (100 bytes overhead + 900 bytes padding)
-- Parameter: batch_id (UUID), passed via psycopg2
INSERT INTO load_test_data (batch_id, counter, category, status, value, description, padding)
SELECT
    %s::uuid,
    g,
    ('cat_' || (g %% 20))::varchar(50),
    (CASE (g %% 5)
        WHEN 0 THEN 'active'
        WHEN 1 THEN 'pending'
        WHEN 2 THEN 'processing'
        WHEN 3 THEN 'completed'
        ELSE 'archived'
    END)::varchar(20),
    round((random() * 99999)::numeric, 2),
    md5(random()::text) || ' generated row ' || g,
    repeat(md5(random()::text), 28)  -- ~896 bytes padding
FROM generate_series(1, 100) AS g;
