-- PostgreSQL Lock Analysis Queries
-- Compatible with PostgreSQL 14-17
-- Usage: kubectl exec -n <ns> <master-pod> -- psql -U postgres -d postgres -f /dev/stdin < locks.sql

-- ============================================================================
-- Lock Summary
-- ============================================================================

SELECT
    locktype,
    mode,
    granted,
    count(*) AS count
FROM pg_locks
GROUP BY locktype, mode, granted
ORDER BY count DESC;

-- ============================================================================
-- Blocked Queries with Blocking Query
-- ============================================================================

SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    blocked.application_name AS blocked_app,
    now() - blocked.query_start AS blocked_duration,
    LEFT(blocked.query, 200) AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.usename AS blocking_user,
    blocking.application_name AS blocking_app,
    blocking.state AS blocking_state,
    LEFT(blocking.query, 200) AS blocking_query,
    blocking_lock.mode AS lock_mode
FROM pg_stat_activity blocked
JOIN pg_locks blocked_lock ON blocked.pid = blocked_lock.pid
JOIN pg_locks blocking_lock
    ON blocked_lock.locktype = blocking_lock.locktype
    AND blocked_lock.database IS NOT DISTINCT FROM blocking_lock.database
    AND blocked_lock.relation IS NOT DISTINCT FROM blocking_lock.relation
    AND blocked_lock.page IS NOT DISTINCT FROM blocking_lock.page
    AND blocked_lock.tuple IS NOT DISTINCT FROM blocking_lock.tuple
    AND blocked_lock.virtualxid IS NOT DISTINCT FROM blocking_lock.virtualxid
    AND blocked_lock.transactionid IS NOT DISTINCT FROM blocking_lock.transactionid
    AND blocked_lock.classid IS NOT DISTINCT FROM blocking_lock.classid
    AND blocked_lock.objid IS NOT DISTINCT FROM blocking_lock.objid
    AND blocked_lock.objsubid IS NOT DISTINCT FROM blocking_lock.objsubid
    AND blocked_lock.pid <> blocking_lock.pid
JOIN pg_stat_activity blocking ON blocking_lock.pid = blocking.pid
WHERE NOT blocked_lock.granted
  AND blocking_lock.granted
ORDER BY blocked_duration DESC;

-- ============================================================================
-- Lock Wait Duration
-- ============================================================================

SELECT
    pid,
    usename,
    application_name,
    client_addr,
    wait_event_type,
    wait_event,
    now() - query_start AS wait_duration,
    state,
    LEFT(query, 200) AS query_preview
FROM pg_stat_activity
WHERE wait_event_type = 'Lock'
  AND pid <> pg_backend_pid()
ORDER BY wait_duration DESC;

-- ============================================================================
-- Advisory Locks
-- ============================================================================

SELECT
    locktype,
    classid,
    objid,
    mode,
    granted,
    pid
FROM pg_locks
WHERE locktype = 'advisory'
ORDER BY pid;

-- ============================================================================
-- Relation-Level Locks (heavy locks on tables)
-- ============================================================================

SELECT
    l.locktype,
    c.relname AS relation,
    l.mode,
    l.granted,
    l.pid,
    a.usename,
    a.application_name,
    a.state,
    now() - a.query_start AS duration,
    LEFT(a.query, 150) AS query_preview
FROM pg_locks l
JOIN pg_class c ON l.relation = c.oid
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE l.locktype = 'relation'
  AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
  AND l.pid <> pg_backend_pid()
ORDER BY l.granted, duration DESC;

-- ============================================================================
-- Deadlock Detection Configuration
-- ============================================================================

SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('deadlock_timeout', 'lock_timeout', 'statement_timeout', 'idle_in_transaction_session_timeout')
ORDER BY name;
