-- Full table scan on unindexed column (description search across inventory)
SELECT count(*), avg(value), min(created_at), max(created_at)
FROM inventory_items
WHERE description LIKE '%' || md5(random()::text) || '%';
