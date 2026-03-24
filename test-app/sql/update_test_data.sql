-- Update random rows: generates CPU load via md5() and creates dead tuples for vacuum
UPDATE load_test_data
SET
    counter    = counter + 1,
    updated_at = now(),
    value      = round((random() * 99999)::numeric, 2),
    description = md5(random()::text) || ' updated'
WHERE id IN (
    SELECT id FROM load_test_data
    ORDER BY random()
    LIMIT 50
);
