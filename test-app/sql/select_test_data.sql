-- Full table scan on unindexed column (forces sequential scan, generates IO load)
SELECT count(*), avg(value), min(created_at), max(created_at)
FROM load_test_data
WHERE description LIKE '%' || md5(random()::text) || '%';
