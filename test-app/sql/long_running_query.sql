-- Cross-join query that produces heavy CPU and IO load.
-- Used when table has enough rows; falls back to pg_sleep() in Python when table is small.
-- statement_timeout is set in the session before executing this query.
SELECT count(*)
FROM load_test_data a
CROSS JOIN load_test_data b
WHERE md5(a.description || b.description) IS NOT NULL;
