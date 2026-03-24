-- PostgreSQL Performance Analysis Queries
-- Compatible with PostgreSQL 14-17
-- Usage: kubectl exec -n <ns> <master-pod> -- psql -U postgres -d postgres -f /dev/stdin < performance.sql

-- ============================================================================
-- Top Slow Queries (requires pg_stat_statements)
-- ============================================================================

SELECT
    queryid,
    LEFT(query, 100) AS query_preview,
    calls,
    round(total_exec_time::numeric, 2) AS total_exec_time_ms,
    round(mean_exec_time::numeric, 2) AS mean_exec_time_ms,
    rows,
    round(100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0), 2) AS cache_hit_pct
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;

-- ============================================================================
-- Currently Active Queries
-- ============================================================================

SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS duration,
    LEFT(query, 200) AS query_preview
FROM pg_stat_activity
WHERE state = 'active'
  AND pid <> pg_backend_pid()
ORDER BY duration DESC;

-- ============================================================================
-- Connection State Summary
-- ============================================================================

SELECT
    state,
    wait_event_type,
    wait_event,
    count(*) AS count,
    round(avg(EXTRACT(EPOCH FROM (now() - query_start)))::numeric, 1) AS avg_duration_sec
FROM pg_stat_activity
WHERE state IS NOT NULL
  AND pid <> pg_backend_pid()
GROUP BY state, wait_event_type, wait_event
ORDER BY count DESC;

-- ============================================================================
-- Cache Hit Ratio
-- ============================================================================

SELECT
    datname,
    blks_hit,
    blks_read,
    CASE
        WHEN (blks_hit + blks_read) > 0
        THEN round(100.0 * blks_hit / (blks_hit + blks_read), 2)
        ELSE 0
    END AS cache_hit_pct
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY pg_database_size(datname) DESC;

-- ============================================================================
-- Table I/O Statistics (Heaviest Tables)
-- ============================================================================

SELECT
    schemaname,
    relname,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS total_size,
    seq_scan,
    idx_scan,
    CASE
        WHEN (seq_scan + idx_scan) > 0
        THEN round(100.0 * idx_scan / (seq_scan + idx_scan), 1)
        ELSE 0
    END AS idx_scan_pct,
    n_tup_ins AS inserts,
    n_tup_upd AS updates,
    n_tup_del AS deletes,
    n_tup_hot_upd AS hot_updates
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname || '.' || relname) DESC
LIMIT 20;

-- ============================================================================
-- Unused Indexes (candidates for removal)
-- ============================================================================

SELECT
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(schemaname || '.' || indexrelname)) AS index_size,
    idx_scan AS scans
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND pg_relation_size(schemaname || '.' || indexrelname) > 1048576
ORDER BY pg_relation_size(schemaname || '.' || indexrelname) DESC;

-- ============================================================================
-- Vacuum & Analyze Health
-- ============================================================================

SELECT
    schemaname,
    relname,
    n_dead_tup AS dead_rows,
    n_live_tup AS live_rows,
    ROUND(n_dead_tup::numeric * 100 / NULLIF(n_live_tup, 0), 2) AS dead_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    vacuum_count + autovacuum_count AS total_vacuums,
    analyze_count + autoanalyze_count AS total_analyzes
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 20;

-- ============================================================================
-- Transaction Throughput
-- ============================================================================

SELECT
    datname,
    xact_commit AS commits,
    xact_rollback AS rollbacks,
    CASE
        WHEN (xact_commit + xact_rollback) > 0
        THEN round(100.0 * xact_rollback / (xact_commit + xact_rollback), 2)
        ELSE 0
    END AS rollback_pct,
    tup_inserted,
    tup_updated,
    tup_deleted,
    tup_fetched
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY xact_commit DESC;
