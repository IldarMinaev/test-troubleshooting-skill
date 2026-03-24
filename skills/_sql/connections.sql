-- PostgreSQL Connection Analysis Queries
-- Compatible with PostgreSQL 14-17
-- Usage: kubectl exec -n <ns> <master-pod> -- psql -U postgres -d postgres -f /dev/stdin < connections.sql

-- ============================================================================
-- Connection State Breakdown
-- ============================================================================

SELECT
    state,
    count(*) AS count,
    round(100.0 * count(*) / NULLIF((SELECT count(*) FROM pg_stat_activity WHERE datname IS NOT NULL), 0), 1) AS pct
FROM pg_stat_activity
WHERE datname IS NOT NULL
GROUP BY state
ORDER BY count DESC;

-- ============================================================================
-- Connections by Application
-- ============================================================================

SELECT
    application_name,
    state,
    count(*) AS count,
    min(backend_start) AS oldest_connection,
    max(query_start) AS latest_query
FROM pg_stat_activity
WHERE datname IS NOT NULL
  AND pid <> pg_backend_pid()
GROUP BY application_name, state
ORDER BY count DESC;

-- ============================================================================
-- Connections by Client Address
-- ============================================================================

SELECT
    client_addr,
    count(*) AS count,
    count(*) FILTER (WHERE state = 'active') AS active,
    count(*) FILTER (WHERE state = 'idle') AS idle,
    count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn
FROM pg_stat_activity
WHERE datname IS NOT NULL
  AND pid <> pg_backend_pid()
GROUP BY client_addr
ORDER BY count DESC;

-- ============================================================================
-- Connection Pool Utilization
-- ============================================================================

SELECT
    (SELECT count(*) FROM pg_stat_activity WHERE datname IS NOT NULL) AS current_connections,
    (SELECT setting::integer FROM pg_settings WHERE name = 'max_connections') AS max_connections,
    (SELECT count(*) FROM pg_stat_activity WHERE datname IS NOT NULL)::numeric /
        (SELECT setting::integer FROM pg_settings WHERE name = 'max_connections') * 100 AS utilization_pct,
    (SELECT setting::integer FROM pg_settings WHERE name = 'superuser_reserved_connections') AS reserved_connections;

-- ============================================================================
-- Idle in Transaction (potential connection leaks)
-- ============================================================================

SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    now() - state_change AS idle_duration,
    now() - xact_start AS transaction_duration,
    LEFT(query, 200) AS last_query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND pid <> pg_backend_pid()
ORDER BY idle_duration DESC;

-- ============================================================================
-- Long-Idle Connections (>1 hour without activity)
-- ============================================================================

SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    now() - state_change AS idle_since,
    backend_start,
    LEFT(query, 200) AS last_query
FROM pg_stat_activity
WHERE state = 'idle'
  AND now() - state_change > interval '1 hour'
  AND pid <> pg_backend_pid()
ORDER BY idle_since DESC;

-- ============================================================================
-- Connections by Database
-- ============================================================================

SELECT
    datname,
    count(*) AS connections,
    count(*) FILTER (WHERE state = 'active') AS active,
    count(*) FILTER (WHERE state = 'idle') AS idle,
    count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn,
    d.datconnlimit AS db_max_connections
FROM pg_stat_activity a
JOIN pg_database d ON a.datname = d.datname
WHERE a.datname IS NOT NULL
GROUP BY datname, d.datconnlimit
ORDER BY connections DESC;

-- ============================================================================
-- Waiting Connections (blocked by locks)
-- ============================================================================

SELECT
    pid,
    usename,
    application_name,
    wait_event_type,
    wait_event,
    now() - query_start AS wait_duration,
    LEFT(query, 200) AS query_preview
FROM pg_stat_activity
WHERE wait_event_type IS NOT NULL
  AND state = 'active'
  AND pid <> pg_backend_pid()
ORDER BY wait_duration DESC;
