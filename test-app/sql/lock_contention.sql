-- Row-level lock contention: hold row locks for a period, causing other sessions to wait.
-- Uses FOR UPDATE NOWAIT so the caller gets an immediate error if the row is already locked.
BEGIN;

-- Lock 5 random rows
SELECT * FROM load_test_data
WHERE id IN (
    SELECT id FROM load_test_data ORDER BY random() LIMIT 5
)
FOR UPDATE NOWAIT;

-- Hold the locks (sleep executed in Python via shutdown_event.wait)
-- Python will COMMIT or ROLLBACK after the hold period.
