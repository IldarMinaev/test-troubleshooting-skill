-- Main table for inventory item storage and processing
CREATE TABLE IF NOT EXISTS inventory_items (
    id          BIGSERIAL PRIMARY KEY,
    batch_id    UUID NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    counter     INTEGER NOT NULL DEFAULT 0,
    category    VARCHAR(50) NOT NULL,
    status      VARCHAR(20) NOT NULL DEFAULT 'active',
    value       NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    description TEXT,
    padding     TEXT
);

-- Indexed columns (for targeted lookups)
CREATE INDEX IF NOT EXISTS idx_inventory_items_category ON inventory_items (category);
CREATE INDEX IF NOT EXISTS idx_inventory_items_status   ON inventory_items (status);
-- description and padding are intentionally NOT indexed to allow full-text search flexibility

-- Accounts table for balance transfers and reconciliation
CREATE TABLE IF NOT EXISTS customer_accounts (
    account_id   BIGSERIAL PRIMARY KEY,
    account_name VARCHAR(100) NOT NULL,
    balance      NUMERIC(12,2) NOT NULL DEFAULT 1000.00,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Seed accounts if table is empty
INSERT INTO customer_accounts (account_name, balance)
SELECT
    'account_' || g,
    round((random() * 10000)::numeric, 2)
FROM generate_series(1, 100) AS g
WHERE NOT EXISTS (SELECT 1 FROM customer_accounts LIMIT 1);
