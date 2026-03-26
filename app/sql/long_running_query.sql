-- Analytical cross-reference query for inventory reporting.
-- Produces heavy CPU and IO load via cross-join.
-- statement_timeout is set in the session before executing this query.
SELECT count(*)
FROM inventory_items a
CROSS JOIN inventory_items b
WHERE md5(a.description || b.description) IS NOT NULL;
