-- Update random rows: recalculate values and refresh descriptions
UPDATE inventory_items
SET
    counter    = counter + 1,
    updated_at = now(),
    value      = round((random() * 99999)::numeric, 2),
    description = md5(random()::text) || ' updated'
WHERE id IN (
    SELECT id FROM inventory_items
    ORDER BY random()
    LIMIT 50
);
