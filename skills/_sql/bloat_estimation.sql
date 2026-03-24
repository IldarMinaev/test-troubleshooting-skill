-- PostgreSQL Bloat Estimation Queries
-- Compatible with PostgreSQL 14-17
-- Usage: kubectl exec -n <ns> <master-pod> -- psql -U postgres -d postgres -f /dev/stdin < bloat_estimation.sql

-- ============================================================================
-- Table Bloat via Dead Tuple Ratio
-- ============================================================================

SELECT
    schemaname,
    relname AS table_name,
    n_live_tup AS live_tuples,
    n_dead_tup AS dead_tuples,
    ROUND(n_dead_tup::numeric * 100 / NULLIF(n_live_tup, 0), 2) AS dead_pct,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname || '.' || relname)) AS table_size,
    CASE
        WHEN n_dead_tup::numeric * 100 / NULLIF(n_live_tup, 0) > 20 THEN 'CRITICAL'
        WHEN n_dead_tup::numeric * 100 / NULLIF(n_live_tup, 0) > 10 THEN 'WARNING'
        ELSE 'OK'
    END AS bloat_status
FROM pg_stat_user_tables
WHERE n_live_tup > 0
  AND n_dead_tup::numeric * 100 / NULLIF(n_live_tup, 0) > 5
ORDER BY dead_pct DESC
LIMIT 30;

-- ============================================================================
-- Tables Needing VACUUM
-- ============================================================================

SELECT
    schemaname,
    relname AS table_name,
    n_dead_tup AS dead_tuples,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    CASE
        WHEN last_autovacuum IS NULL AND last_vacuum IS NULL THEN 'NEVER_VACUUMED'
        WHEN GREATEST(COALESCE(last_autovacuum, '1970-01-01'), COALESCE(last_vacuum, '1970-01-01')) < now() - interval '1 day'
             AND n_dead_tup > 10000 THEN 'OVERDUE'
        WHEN n_dead_tup > 50000 THEN 'HIGH_DEAD_TUPLES'
        ELSE 'OK'
    END AS vacuum_status
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 20;

-- ============================================================================
-- Autovacuum Activity
-- ============================================================================

SELECT
    schemaname,
    relname,
    vacuum_count,
    autovacuum_count,
    analyze_count,
    autoanalyze_count,
    last_vacuum,
    last_autovacuum,
    n_dead_tup,
    n_live_tup
FROM pg_stat_user_tables
WHERE n_live_tup > 1000
ORDER BY autovacuum_count DESC
LIMIT 20;

-- ============================================================================
-- Autovacuum Workers Status
-- ============================================================================

SELECT
    pid,
    datname,
    usename,
    LEFT(query, 100) AS activity,
    now() - query_start AS duration
FROM pg_stat_activity
WHERE query LIKE 'autovacuum:%'
ORDER BY duration DESC;

-- ============================================================================
-- Tables Approaching Wraparound (XID age)
-- ============================================================================

SELECT
    c.relnamespace::regnamespace AS schema_name,
    c.relname AS table_name,
    age(c.relfrozenxid) AS xid_age,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    CASE
        WHEN age(c.relfrozenxid) > 1500000000 THEN 'CRITICAL'
        WHEN age(c.relfrozenxid) > 1000000000 THEN 'WARNING'
        ELSE 'OK'
    END AS wraparound_risk
FROM pg_class c
WHERE c.relkind = 'r'
  AND c.relnamespace NOT IN (SELECT oid FROM pg_namespace WHERE nspname IN ('pg_catalog', 'information_schema'))
ORDER BY age(c.relfrozenxid) DESC
LIMIT 20;

-- ============================================================================
-- Index Bloat Indicators
-- ============================================================================

SELECT
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(schemaname || '.' || indexrelname)) AS index_size,
    idx_scan AS scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    CASE
        WHEN idx_scan = 0 THEN 'UNUSED'
        WHEN idx_tup_fetch::numeric / NULLIF(idx_tup_read, 0) < 0.1 THEN 'LOW_EFFICIENCY'
        ELSE 'OK'
    END AS efficiency
FROM pg_stat_user_indexes
WHERE pg_relation_size(schemaname || '.' || indexrelname) > 10485760
ORDER BY pg_relation_size(schemaname || '.' || indexrelname) DESC
LIMIT 20;
