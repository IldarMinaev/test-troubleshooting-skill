-- Inventory audit: lock sampled rows while verifying counts.
-- Uses FOR UPDATE NOWAIT so the caller gets an immediate error if the row is already locked.
BEGIN;

-- Lock 5 random rows
SELECT * FROM inventory_items
WHERE id IN (
    SELECT id FROM inventory_items ORDER BY random() LIMIT 5
)
FOR UPDATE NOWAIT;

-- Hold the locks (sleep executed in Python via shutdown_event.wait)
-- Python will COMMIT or ROLLBACK after the hold period.
